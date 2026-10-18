;; ABOUTME: Evaluates Arazzo runtime expressions, templates, Selector Objects
;; ABOUTME: and criteria against a workflow execution context.
;; Handles: $inputs.x, $steps.id.outputs.x, $statusCode,
;;          $response.body#/ptr, $response.header.X,
;;          $request.body#/ptr, $url, $method, $outputs.x, $self,
;;          $workflows.id.inputs.x, $workflows.id.outputs.x,
;;          $sourceDescriptions.name.operationId (or .url, .type…),
;;          template strings "text {$expr} text",
;;          Selector Objects (JSONPath, JSON Pointer)
(local util (require :ezu.util))
(local json (require :ezu.json))
(local jsonpath (require :ezu.jsonpath))
(local iregexp (require :ezu.iregexp))

;; ---- JSON Pointer ----

(fn json-pointer [obj ptr]
  "Resolve a JSON Pointer string (/foo/0/bar) into obj; nil for an empty pointer."
  (when (and obj ptr (> (length ptr) 0))
    (util.json-pointer obj ptr)))

;; ---- expression resolution ----

(fn with-pointer [value expr]
  "Apply the #/json/pointer suffix of expr to value, when present."
  (let [ptr (expr:match "#(.+)$")]
    (if ptr (json-pointer value ptr) value)))

(fn named [entries parts from kind expr]
  "The entry of entries named by parts from index from on, rejoined with dots
(names may contain dots), with expr's #/pointer applied. When no entry has
that name but one is named by its first part, the expression most likely
meant a JSON pointer into it: raise saying so."
  (let [name (table.concat parts "." from)
        value (?. entries name)]
    (when (and (= nil value) (> (length parts) from)
               (not= nil (?. entries (. parts from))))
      (error (string.format "%s: there is no %s '%s'; for a value inside '%s' use $%s#/%s"
                            expr kind name (. parts from)
                            (table.concat parts "." 1 from)
                            (table.concat parts "/" (+ from 1))) 0))
    (with-pointer value expr)))

(fn unknown [expr]
  (error (.. "unknown runtime expression: " expr) 0))

(fn message-value [msg parts expr]
  "Resolve body, header, query or path access on a request/response;
parts = [body] or [header|query|path name...]."
  (let [name (when (. parts 2) (table.concat parts "." 2))]
    (match (. parts 1)
      ;; only a #/pointer may follow body
      (where :body (= nil name))
      (with-pointer (?. msg :body) expr)
      (where :header name)
      (util.header (?. msg :headers) name)
      (where :query name)
      (?. msg :query name)
      (where :path name)
      (?. msg :path name)
      _
      (unknown expr))))

(fn resolve-expr [ctx expr]
  "Resolve a single $... runtime expression to a value."
  (let [e (expr:match "^%$(.+)")]
    (when (not e) (error (.. "not a runtime expression: " expr) 0))
    (let [head (or (e:match "^([^#]+)") "")
          parts (icollect [p (head:gmatch "[^%.]+")] p)
          rest-from #(icollect [i p (ipairs parts)] (when (>= i $) p))]
      (match (. parts 1)
        :inputs
        (named ctx.inputs parts 2 :input expr)
        :statusCode
        (?. ctx :response :status)
        :url
        (?. ctx :request :url)
        :method
        (?. ctx :request :method)
        :response
        (message-value ctx.response (rest-from 2) expr)
        :request
        (message-value ctx.request (rest-from 2) expr)
        :steps
        (let [step (?. ctx :steps (. parts 2))]
          (match (. parts 3)
            :outputs (named (?. step :outputs) parts 4 :output expr)
            :response (message-value (?. step :response) (rest-from 4) expr)
            :request (message-value (?. step :request) (rest-from 4) expr)
            _ (unknown expr)))
        :workflows
        (match (. parts 3)
          :outputs (named (?. ctx :workflows (. parts 2) :outputs) parts 4
                          :output expr)
          :inputs (named (?. ctx :workflows (. parts 2) :inputs) parts 4 :input
                         expr)
          _ (unknown expr))
        :outputs
        (named ctx.outputs parts 2 :output expr)
        :self
        ctx.self
        :message
        (error (.. expr ": AsyncAPI messages are not supported") 0)
        ;; a sentinel table so the caller can look up the client
        :sourceDescriptions
        ;; source names have no dots, operationIds may
        {:__source (. parts 2) :__operationId (table.concat parts "." 3)}
        _
        (unknown expr)))))

;; ---- template substitution ----

(fn source-field [ctx v]
  "v, or for $sourceDescriptions.NAME.FIELD the source's FIELD (url, type…)."
  (if (and (= (type v) :table) v.__source)
      (?. ctx :sources v.__source v.__operationId)
      v))

(fn eval-template [ctx s]
  "Substitute {$expr} occurrences in s."
  (pick-values 1 (s:gsub "{(%$[^}]+)}"
                         (fn [expr]
                           (let [v (source-field ctx (resolve-expr ctx expr))]
                             ;; null is no value, like a missing one;
                             ;; structured values as JSON
                             (if (or (= v nil) (= v json.null)) ""
                                 (= (type v) :table) (json.encode v)
                                 (tostring v)))))))

(fn eval-jsonpath-template [ctx s]
  "s, a JSONPath query, with its {$expr} replaced by their values as the query
reads them: inside a string literal, the value's text escaped for its quotes,
so a value can't change the query; elsewhere, a string as it is and other
values as JSON literals (null when missing)."
  (let [out []]
    (var delimiter nil)
    (var i 1)
    (while (<= i (length s))
      (let [c (s:sub i i)
            expr (s:match "^{(%$[^}]+)}" i)]
        (if expr
            (let [v (source-field ctx (resolve-expr ctx expr))
                  missing (or (= v nil) (= v json.null))]
              (table.insert out
                            (if delimiter
                                (jsonpath.escape-string (if missing ""
                                                            (= (type v) :table)
                                                            (json.encode v)
                                                            (tostring v))
                                                        delimiter)
                                missing
                                "null"
                                ;; text, as the spec has it: a member name or
                                ;; an index, say
                                (= (type v) :string)
                                v
                                (json.encode v)))
              (set i (+ i (length expr) 2)))
            (do
              (table.insert out c)
              (if (and delimiter (= c "\\"))
                  (do
                    (table.insert out (s:sub (+ i 1) (+ i 1)))
                    (set i (+ i 2)))
                  (do
                    (if (= c delimiter) (set delimiter nil)
                        (and (not delimiter) (or (= c "'") (= c "\""))) (set delimiter
                                                                             c))
                    (set i (+ i 1))))))))
    (table.concat out)))

(local roots {:inputs true
              :outputs true
              :self true
              :message true
              :statusCode true
              :url true
              :method true
              :response true
              :request true
              :steps true
              :workflows true
              :sourceDescriptions true})

(fn expression? [s]
  "Whether s is a runtime expression: $ followed by a known root."
  (not= nil (. roots (or (s:match "^%$(%a+)") ""))))

;; ---- Selector Objects ----

(fn expression-type [t]
  "The kind of a criterion's or Selector Object's type (a name or an
Expression Type Object): simple, regex, jsonpath or jsonpointer; raises for
XPath and versions ezu doesn't implement."
  (let [kind (if (= (type t) :table) t.type t)
        version (when (= (type t) :table) t.version)]
    (match kind
      (where (or :simple :regex)) kind
      :jsonpath (if (or (= nil version) (= version :rfc9535)) kind
                    (error (.. "JSONPath version " (tostring version)
                               " is not supported (rfc9535 is)")
                           0))
      :jsonpointer (if (or (= nil version) (= version :rfc6901)) kind
                       (error (.. "JSON Pointer version " (tostring version)
                                  " is not supported (rfc6901 is)")
                              0))
      :xpath (error "XPath is not supported: ezu reads JSON, not XML" 0)
      _ (error (.. "unknown expression type: " (tostring kind)) 0))))

(fn selector-object? [v]
  "Whether v is a Selector Object: context, selector and type, besides x-
extensions; any other table is data."
  (and (= (type v) :table) (not= v json.null) (not (json.array? v))
       (= (type v.context) :string) (= (type v.selector) :string)
       (not= nil v.type)
       (accumulate [only true k (pairs v) &until (not only)]
         (or (= k :context) (= k :selector) (= k :type)
             (and (= (type k) :string) (k:match "^x%-") true)))))

(var eval nil)

(fn eval-member [ctx v]
  "The value of an object member or an array item: an object or array whose
members or items all resolve to nothing is nothing too, so optional inputs
can fill nested objects and lists. The payload itself, and an object or array
written empty ({}, []), stay as they are."
  (let [value (eval ctx v)]
    (when (not (and (= (type v) :table) (not= v json.null)
                    (not (selector-object? v)) (next v) (= (type value) :table)
                    (= nil (next value))))
      value)))

(fn eval-selector [ctx obj]
  "What a Selector Object selects. A singular JSONPath query (names and indexes
only, RFC 9535) selects its node's value, or nil; any other query an array of
its nodes' values, empty when there are none, so a result's type doesn't
depend on the data. Runtime expressions may be embedded in the selector with
{}, as in conditions."
  (let [kind (expression-type obj.type)
        data (eval ctx obj.context)
        selector (if (= kind :jsonpath)
                     (eval-jsonpath-template ctx obj.selector)
                     (eval-template ctx obj.selector))]
    (match kind
      :jsonpath (let [;; held, so that the query reuses it from the cache
                      query (jsonpath.compile selector)
                      nodes (jsonpath.query selector data)]
                  (if query.singular
                      (?. nodes 1 :value)
                      (json.array (icollect [_ n (ipairs nodes)]
                                    n.value))))
      :jsonpointer (util.json-pointer data (selector:gsub "^#" ""))
      _ (error (.. "a selector can't be of type " kind) 0))))

(set eval (fn [ctx expr]
            "Evaluate an Arazzo expression, template string, Selector Object or table
(recursively). Text that only starts with $ (\"$5\") is not an expression
and stays as is."
            (if (and (= (type expr) :string) (expression? expr))
                (resolve-expr ctx expr)
                (and (= (type expr) :string) (expr:match "{%$"))
                (eval-template ctx expr)
                (= expr json.null)
                expr
                (selector-object? expr)
                (eval-selector ctx expr)
                ;; arrays stay arrays, without the items that resolve to nothing; a
                ;; null written as an item stays
                (json.array? expr)
                (json.array (icollect [_ item (ipairs expr)]
                              (eval-member ctx item)))
                (= (type expr) :table)
                (collect [k v (pairs expr)]
                  k
                  (eval-member ctx v))
                expr)))

;; ---- simple condition language ----
;; Grammar (Arazzo 1.0 "simple" criteria):
;;   or    := and ('||' and)*
;;   and   := unary ('&&' unary)*
;;   unary := '!' unary | cmp
;;   cmp   := value (('=='|'!='|'<'|'<='|'>'|'>=') value)?
;;   value := '(' or ')' | $expr | 'str' | "str" | number | true | false | null | word
;; Runtime expressions are resolved to values and never re-parsed.

(local null json.null)

(local operators ["==" "!=" "<=" ">=" "&&" "||" "<" ">" "!" "(" ")"])

(fn read-string-literal [s pos]
  "Read a quoted literal starting at pos; returns (text next-pos). As in the
Arazzo spec, a doubled quote stands for the quote itself."
  (let [delimiter (s:sub pos pos)
        out []]
    (var i (+ pos 1))
    (var done false)
    (while (not done)
      (let [ch (s:sub i i)]
        (if (= ch "") (error (.. "unterminated string in condition: " s) 0)
            (and (= ch delimiter) (= (s:sub (+ i 1) (+ i 1)) delimiter))
            (do
              (table.insert out delimiter)
              (set i (+ i 2))) (= ch delimiter)
            (do
              (set done true)
              (set i (+ i 1)))
            (do
              (table.insert out ch)
              (set i (+ i 1))))))
    (values (table.concat out) i)))

(fn tokenize [s]
  (let [tokens []]
    (var pos 1)
    (while (<= pos (length s))
      (let [ws-end (s:match "^%s*()" pos)]
        (set pos ws-end)
        (when (<= pos (length s))
          (let [ch (s:sub pos pos)
                expr (s:match "^%$[^%s()=!<>&|]+" pos)
                number (s:match "^%-?%d+%.?%d*[eE][%+%-]?%d+" pos)
                number (or number (s:match "^%-?%d+%.?%d*" pos))
                word (s:match "^[%a_][%w_%-%.]*" pos)
                op (accumulate [found nil _ o (ipairs operators) &until found]
                     (when (= (s:sub pos (+ pos (length o) -1)) o)
                       o))]
            (if expr (do
                       (table.insert tokens {:kind :expr :text expr})
                       (set pos (+ pos (length expr))))
                (or (= ch "'") (= ch "\""))
                (let [(text next-pos) (read-string-literal s pos)]
                  (table.insert tokens {:kind :literal :value text})
                  (set pos next-pos)) number
                (do
                  (table.insert tokens
                                {:kind :literal :value (tonumber number)})
                  (set pos (+ pos (length number)))) op
                (do
                  (table.insert tokens {:kind :op :text op})
                  (set pos (+ pos (length op)))) word
                (do
                  (table.insert tokens
                                {:kind :literal
                                 :value (match word "true" true "false" false
                                          "null" null
                                          _ word)})
                  (set pos (+ pos (length word))))
                (error (.. "unexpected character '" ch "' in condition: " s) 0))))))
    tokens))

(fn numeric-pair [a b]
  "Coerce a numeric string to a number when compared against a number."
  (if (and (= (type a) :number) (= (type b) :string) (tonumber b))
      (values a (tonumber b))
      (and (= (type a) :string) (= (type b) :number) (tonumber a))
      (values (tonumber a) b)
      (values a b)))

(fn token-text [t]
  (if t.text t.text
      (= t.value null) "null"
      (tostring t.value)))

(fn truthy? [v]
  (and (not= v nil) (not= v false) (not= v null)))

(fn normalize [v]
  (if (= v null) nil v))

(fn fold-case [a b]
  "Strings compare case-insensitively, as the Arazzo spec requires."
  (if (and (= (type a) :string) (= (type b) :string))
      (values (a:lower) (b:lower))
      (values a b)))

(fn equal? [a b]
  (let [(a b) (fold-case (numeric-pair (normalize a) (normalize b)))]
    (= a b)))

(fn ordered [op a b]
  (let [(a b) (fold-case (numeric-pair (normalize a) (normalize b)))
        comparable (or (and (= (type a) :number) (= (type b) :number))
                       (and (= (type a) :string) (= (type b) :string)))]
    (and comparable (match op
                      "<" (< a b)
                      "<=" (<= a b)
                      ">" (> a b)
                      ">=" (>= a b)))))

;; The evaluator works on a parser table:
;; {:tokens [...] :pos index :ctx runtime-context :condition source-text}

(local comparison-ops {"==" true
                       "!=" true
                       "<" true
                       "<=" true
                       ">" true
                       ">=" true})

(fn fail [parser message]
  (error (.. message " in condition: " parser.condition) 0))

(fn peek [parser]
  (. parser.tokens parser.pos))

(fn op? [parser text]
  (let [t (peek parser)]
    (and t (= t.kind :op) (= t.text text))))

(fn advance [parser]
  (set parser.pos (+ parser.pos 1))
  (. parser.tokens (- parser.pos 1)))

(var parse-or nil)

(fn parse-value [parser]
  (let [t (advance parser)]
    (if (= t nil) (fail parser "unexpected end")
        (and (= t.kind :op) (= t.text "("))
        (let [v (parse-or parser)]
          (if (op? parser ")") (advance parser) (fail parser "missing )"))
          v) (= t.kind :expr) (resolve-expr parser.ctx t.text)
        (= t.kind :literal) t.value (fail parser (.. "unexpected '" t.text "'")))))

(fn parse-cmp [parser]
  (let [left (parse-value parser)
        t (peek parser)]
    (if (and t (= t.kind :op) (. comparison-ops t.text))
        (let [op (. (advance parser) :text)
              right (parse-value parser)]
          (match op
            "==" (equal? left right)
            "!=" (not (equal? left right))
            _ (ordered op left right)))
        left)))

(fn parse-unary [parser]
  (if (op? parser "!")
      (do
        (advance parser)
        (not (truthy? (parse-unary parser))))
      (parse-cmp parser)))

(fn parse-and [parser]
  (var v (truthy? (parse-unary parser)))
  (while (op? parser "&&")
    (advance parser)
    (let [r (truthy? (parse-unary parser))]
      (set v (and v r))))
  v)

(set parse-or (fn [parser]
                (var v (parse-and parser))
                (while (op? parser "||")
                  (advance parser)
                  (let [r (parse-and parser)]
                    (set v (or v r))))
                v))

(fn eval-condition [ctx condition]
  "Evaluate a simple condition string; raises on syntax errors."
  (let [parser {:tokens (tokenize condition) :pos 1 : ctx : condition}
        result (parse-or parser)]
    (when (peek parser)
      (fail parser (.. "unexpected '" (token-text (peek parser)) "'")))
    (truthy? result)))

;; ---- criterion evaluation ----

(fn passes? [ctx criterion kind]
  ;; runtime expressions in regex and JSONPath conditions are embedded with
  ;; {} and substituted first; a missing context passes nothing
  (match kind
    :simple (eval-condition ctx criterion.condition)
    :regex (let [v (eval ctx criterion.context)]
             (and (not= nil v) (not= json.null v)
                  (iregexp.search? (iregexp.compile (eval-template ctx
                                                                   criterion.condition)
                                                    {:ecmascript true})
                                   (tostring v))))
    :jsonpath (let [v (eval ctx criterion.context)]
                (and (not= nil v) (not= json.null v)
                     (< 0 (length (jsonpath.query (eval-jsonpath-template ctx
                                                                          criterion.condition)
                                                  v)))))
    _ (error (.. "a condition can't be of type " kind) 0)))

(fn eval-criterion [ctx criterion]
  "Evaluate one Criterion Object: (passed problem). A condition that can't be
evaluated (a malformed or misspelled expression) fails, with problem saying
why, as Arazzo 1.1 requires; an unsupported type raises."
  (let [kind (expression-type (or criterion.type :simple))
        (ok result) (pcall passes? ctx criterion kind)]
    (if ok
        (values (= true result))
        (values false
                (.. "condition '" (tostring criterion.condition)
                    "' can't be evaluated: " (tostring result))))))

(fn condition-expressions [condition]
  "The runtime expressions of a simple condition, as written; raises when it
can't be read."
  (icollect [_ token (ipairs (tokenize condition))]
    (when (= token.kind :expr) token.text)))

(fn failing-criterion [ctx criteria]
  "The first of criteria that doesn't pass, or nil. Problems evaluating them
go to ctx.warn."
  (accumulate [failing nil _ c (ipairs (or criteria [])) &until failing]
    (let [(passed problem) (eval-criterion ctx c)]
      (when (and problem ctx.warn)
        (ctx.warn problem))
      (when (not passed) c))))

(fn eval-criteria [ctx criteria]
  "Whether all criteria pass. Problems evaluating them go to ctx.warn."
  (= nil (failing-criterion ctx criteria)))

;; ---- explanations ----

;; values longer than this are cut in explanations
(local shown-length 60)

(fn cut [text max-length]
  "text cut to max-length characters with …, between characters (bytes when
it isn't UTF-8)."
  (let [n (utf8.len text)]
    (if (<= (or n (length text)) max-length) text
        (.. (text:sub 1 (if n (- (utf8.offset text (+ max-length 1)) 1)
                            max-length)) "…"))))

(fn brief [v ?max-length]
  "v as JSON text of at most ?max-length characters (60 by default), cut with
…, for a person reading why a criterion failed; missing for nil."
  (if (= v nil) "missing" (cut (json.encode v) (or ?max-length shown-length))))

(fn explain-criterion [ctx criterion]
  "Why criterion doesn't pass, for a person: a simple condition with the values
of its runtime expressions, a regex or JSONPath condition as evaluated with
its context's value, or why it can't be evaluated."
  (let [(_ problem) (eval-criterion ctx criterion)
        kind (expression-type (or criterion.type :simple))]
    (if problem problem (= kind :simple)
        (let [seen {}
              parts (icollect [_ token (ipairs (tokenize criterion.condition))]
                      (when (and (= token.kind :expr) (not (. seen token.text)))
                        (tset seen token.text true)
                        (.. token.text " is "
                            (brief (resolve-expr ctx token.text)))))]
          (if (next parts)
              (.. criterion.condition " (" (table.concat parts ", ") ")")
              criterion.condition))
        ;; the condition as evaluated: embedded {$expressions} substituted
        (.. kind " "
            (if (= kind :jsonpath)
                (eval-jsonpath-template ctx criterion.condition)
                (eval-template ctx criterion.condition))
            (if (= kind :regex) " doesn't match " " selects nothing in ")
            (tostring criterion.context) " ("
            (brief (eval ctx criterion.context)) ")"))))

{: eval
 : expression-type
 : selector-object?
 : eval-template
 : resolve-expr
 : eval-criterion
 : failing-criterion
 : explain-criterion
 : condition-expressions
 : brief
 : cut
 : eval-criteria
 : json-pointer}
