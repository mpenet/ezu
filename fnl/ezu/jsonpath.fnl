;; ABOUTME: JSONPath (RFC 9535): parses and type-checks queries, and selects the
;; ABOUTME: nodes of a JSON value with their locations (normalized paths).
(local json (require :ezu.json))
(local iregexp (require :ezu.iregexp))

;; ---- values ----

;; the absence of a value (RFC 9535 Nothing), distinct from null
(local nothing (setmetatable {} {:__tostring #"Nothing"}))

(fn object? [v]
  (and (= (type v) :table) (not= v json.null) (not= v nothing)
       (not (json.array? v))))

(fn array? [v]
  (and (= (type v) :table) (not= v json.null) (json.array? v)))

(fn sorted-keys [obj]
  "An object's member names in a fixed order: JSON objects are unordered."
  (doto (icollect [k (pairs obj)] k)
    (table.sort)))

;; ---- parsing ----
;; The parser works on {:s query-text :i byte-position}. Every function that
;; parses returns a node, or raises with fail.

(local max-int 9007199254740991)

; 2^53 - 1, the I-JSON integer range

(fn fail [p why]
  (error (string.format "invalid JSONPath query: %s at position %d in %s" why
                        p.i p.s) 0))

(fn peek [p ?n]
  (p.s:sub p.i (+ p.i (or ?n 1) -1)))

(fn at? [p text]
  (= (p.s:sub p.i (+ p.i (length text) -1)) text))

(fn skip [p ?n]
  (set p.i (+ p.i (or ?n 1))))

(fn expect [p text]
  (if (at? p text) (skip p (length text)) (fail p (.. "expected " text))))

(fn blank [p]
  "Skip blank space (space, tab, line feed, carriage return)."
  (set p.i (or (p.s:match "^[ \t\n\r]*()" p.i) p.i)))

(fn int [p]
  "An integer: 0, or digits not starting with 0, optionally negative; within
the I-JSON range."
  (let [text (or (p.s:match "^%-?[1-9]%d*" p.i) (p.s:match "^0" p.i)
                 (fail p "expected an integer"))
        n (tonumber text)]
    (when (or (> n max-int) (< n (- max-int)))
      (fail p "integer out of range"))
    (skip p (length text))
    (math.tointeger n)))

(fn hex-code [p]
  "The code point of \\uXXXX (after the \\u), surrogate pairs joined."
  (let [hex (p.s:match "^%x%x%x%x" p.i)
        _ (when (not hex) (fail p "expected 4 hex digits after \\u"))
        n (tonumber hex 16)]
    (skip p 4)
    (if (and (>= n 0xDC00) (<= n 0xDFFF)) (fail p "lone low surrogate")
        (and (>= n 0xD800) (<= n 0xDBFF))
        (let [low (and (at? p "\\u") (p.s:match "^\\u(%x%x%x%x)" p.i))
              low (and low (tonumber low 16))]
          (when (not (and low (>= low 0xDC00) (<= low 0xDFFF)))
            (fail p "high surrogate without its low half"))
          (skip p 6)
          (+ 0x10000 (* (- n 0xD800) 0x400) (- low 0xDC00))) n)))

(local escapes {:b "\b" :f "\f" :n "\n" :r "\r" :t "\t" "/" "/" "\\" "\\"})

(fn string-literal [p]
  "A string between ' or \" quotes, with JSON escapes."
  (let [delimiter (peek p)
        out []]
    (skip p)
    (while (not (at? p delimiter))
      (let [c (peek p)]
        (if (= c "") (fail p "unterminated string")
            (< (string.byte c) 0x20) (fail p "control character in string")
            (= c "\\") (let [e (peek p 2)
                             e (e:sub 2)]
                         (skip p 2)
                         (if (= e delimiter) (table.insert out delimiter)
                             (. escapes e) (table.insert out (. escapes e))
                             (= e :u) (table.insert out
                                                    (utf8.char (hex-code p)))
                             (fail p (.. "bad escape \\" e))))
            (do
              (table.insert out c)
              (skip p)))))
    (skip p)
    (table.concat out)))

(fn member-name [p]
  "A member name written without quotes: a letter, _ or non-ASCII character,
then those or digits."
  (let [name (or (p.s:match "^[A-Za-z_\128-\255][A-Za-z0-9_\128-\255]*" p.i)
                 (fail p "expected a member name"))]
    (skip p (length name))
    name))

(local functions {:length {:params [:value] :result :value}
                  :count {:params [:nodes] :result :value}
                  :match {:params [:value :value] :result :logical}
                  :search {:params [:value :value] :result :logical}
                  :value {:params [:nodes] :result :value}})

(var parse-or nil)
(var segments nil)

(fn literal [p]
  "A number, string, true, false or null; nil when none starts here."
  (let [c (peek p)]
    (if (or (= c "'") (= c "\"")) {:kind :literal :value (string-literal p)}
        (let [word (p.s:match "^%a+" p.i)
              number (or (p.s:match "^%-?0%.%d+[eE][%-+]?%d+" p.i)
                         (p.s:match "^%-?[1-9]%d*%.%d+[eE][%-+]?%d+" p.i)
                         (p.s:match "^%-?0[eE][%-+]?%d+" p.i)
                         (p.s:match "^%-?[1-9]%d*[eE][%-+]?%d+" p.i)
                         (p.s:match "^%-?0%.%d+" p.i)
                         (p.s:match "^%-?[1-9]%d*%.%d+" p.i)
                         (p.s:match "^%-?0" p.i) (p.s:match "^%-?[1-9]%d*" p.i))]
          (if (and word (or (= word :true) (= word :false) (= word :null))
                   (not (p.s:match "^[%w_(]" (+ p.i (length word)))))
              (do
                (skip p (length word))
                {:kind :literal
                 :value (match word
                          :true true
                          :false false
                          :null json.null)})
              number
              (do
                (skip p (length number))
                ;; digits right after are a leading zero (01)
                (when (p.s:match "^%d" p.i)
                  (fail p "leading zero in number"))
                {:kind :literal :value (tonumber number)}))))))

(fn query [p]
  "A query from $ or @: {:kind :query :root bool :segments [...] :singular bool}."
  (let [root (= (peek p) "$")]
    (skip p)
    (let [segs (segments p)]
      {:kind :query
       : root
       :segments segs
       :singular (accumulate [ok true _ seg (ipairs segs) &until (not ok)]
                   (and (not seg.descendant) (= 1 (length seg.selectors))
                        (let [kind (. seg.selectors 1 :kind)]
                          (or (= kind :name) (= kind :index)))))})))

(fn function-call [p]
  "name(args…), its arguments checked against its parameter types."
  (let [name (p.s:match "^[a-z][a-z0-9_]*" p.i)
        f (. functions name)]
    (when (not f) (fail p (.. "unknown function " name)))
    (skip p (length name))
    (expect p "(")
    (blank p)
    (let [args []]
      (when (not (at? p ")"))
        (table.insert args (parse-or p))
        (blank p)
        (while (at? p ",")
          (skip p)
          (blank p)
          (table.insert args (parse-or p))
          (blank p)))
      (expect p ")")
      (when (not= (length args) (length f.params))
        (fail p (string.format "%s() takes %d argument(s)" name
                               (length f.params))))
      (each [i param (ipairs f.params)]
        (let [arg (. args i)
              ok (match param
                   :value (or (= arg.kind :literal)
                              (and (= arg.kind :query) arg.singular)
                              (and (= arg.kind :function) (= arg.result :value)))
                   :nodes (or (= arg.kind :query)
                              (and (= arg.kind :function) (= arg.result :nodes)))
                   :logical (or (= arg.kind :logical)
                                (and (= arg.kind :function)
                                     (or (= arg.result :logical)
                                         (= arg.result :nodes)))))]
          (when (not ok)
            (fail p (string.format "argument %d of %s() has the wrong type" i
                                   name)))))
      {:kind :function : name :result f.result : args})))

(fn primary [p]
  "A literal, a query or a function call."
  (let [c (peek p)]
    (if (or (= c "$") (= c "@")) (query p)
        (or (literal p)
            (if (p.s:match "^[a-z][a-z0-9_]*%(" p.i) (function-call p)
                (fail p "expected a value, a query or a function"))))))

(fn as-logical [p node]
  "node in a logical context: a query tests for existence, a function must
give a logical value or nodes."
  (match node.kind
    :logical node
    :query {:kind :logical :op :exists :query node}
    :function (if (= node.result :logical)
                  {:kind :logical :op :call :call node}
                  (= node.result :nodes)
                  {:kind :logical :op :exists :query node}
                  (fail p (.. node.name "() isn't a test")))
    _ (fail p "a literal isn't a test")))

(fn comparable [p node]
  "node as one side of a comparison: a literal, a singular query or a
function giving a value."
  (when (not (or (= node.kind :literal)
                 (and (= node.kind :query) node.singular)
                 (and (= node.kind :function) (= node.result :value))))
    (fail p "can't compare that"))
  node)

(local comparison-ops ["==" "!=" "<=" ">=" "<" ">"])

(fn basic [p]
  (if (at? p "!")
      (do
        (skip p)
        (blank p)
        (let [inner (if (at? p "(")
                        (do
                          (skip p)
                          (blank p)
                          (let [e (as-logical p (parse-or p))]
                            (blank p)
                            (expect p ")")
                            e))
                        (let [c (peek p)]
                          (when (not (or (= c "$") (= c "@") (c:match "[a-z]")))
                            (fail p "! needs a query, a function or ( )"))
                          (as-logical p (primary p))))]
          {:kind :logical :op :not :expr inner}))
      (at? p "(")
      (do
        (skip p)
        (blank p)
        (let [e (as-logical p (parse-or p))]
          (blank p)
          (expect p ")")
          e))
      (let [left (primary p)
            save p.i
            _ (blank p)
            op (accumulate [found nil _ o (ipairs comparison-ops) &until found]
                 (when (at? p o) o))]
        (if op
            (do
              (skip p (length op))
              (blank p)
              {:kind :logical
               :op :compare
               :cmp op
               :left (comparable p left)
               :right (comparable p (primary p))})
            (do
              (set p.i save)
              left)))))

(fn joined [p first op-text kind next-fn]
  (var node first)
  (var more true)
  (while more
    (let [save p.i]
      (blank p)
      (if (at? p op-text)
          (do
            (skip p 2)
            (blank p)
            (let [right (as-logical p (next-fn p))]
              (set node {:kind :logical
                         :op kind
                         :left (if (= node.kind :logical) node
                                   (as-logical p node))
                         : right})))
          (do
            (set p.i save)
            (set more false)))))
  node)

(fn parse-and [p]
  (joined p (basic p) "&&" :and basic))

(set parse-or (fn [p]
                (joined p (parse-and p) "||" :or parse-and)))

(fn slice-or-index [p]
  (let [start (when (p.s:match "^%-?%d" p.i) (int p))
        save p.i]
    (blank p)
    (if (at? p ":")
        (do
          (skip p)
          (blank p)
          (let [end (when (p.s:match "^%-?%d" p.i) (int p))
                save2 p.i]
            (blank p)
            (if (at? p ":")
                (do
                  (skip p)
                  (blank p)
                  (let [step (when (p.s:match "^%-?%d" p.i) (int p))]
                    {:kind :slice : start : end : step}))
                (do
                  (set p.i save2)
                  {:kind :slice : start : end}))))
        (do
          (set p.i save)
          (when (= start nil) (fail p "expected a selector"))
          {:kind :index :index start}))))

(fn selector [p]
  (let [c (peek p)]
    (if (or (= c "'") (= c "\"")) {:kind :name :name (string-literal p)}
        (= c "*") (do
                    (skip p)
                    {:kind :wildcard})
        (= c "?") (do
                    (skip p)
                    (blank p)
                    {:kind :filter :expr (as-logical p (parse-or p))})
        (slice-or-index p))))

(fn bracketed [p]
  (expect p "[")
  (blank p)
  (let [selectors [(selector p)]]
    (blank p)
    (while (at? p ",")
      (skip p)
      (blank p)
      (table.insert selectors (selector p))
      (blank p))
    (expect p "]")
    selectors))

(fn segment [p]
  "A segment after its blank space: .name, .*, [...], or the same after ..
for descendants."
  (if (at? p "..")
      (do
        (skip p 2)
        {:descendant true
         :selectors (if (at? p "[") (bracketed p) (at? p "*")
                        (do
                          (skip p)
                          [{:kind :wildcard}])
                        [{:kind :name :name (member-name p)}])})
      (at? p ".")
      (do
        (skip p)
        {:selectors (if (at? p "*")
                        (do
                          (skip p)
                          [{:kind :wildcard}])
                        [{:kind :name :name (member-name p)}])})
      {:selectors (bracketed p)}))

(set segments (fn [p]
                (let [segs []]
                  (var more true)
                  (while more
                    (let [save p.i]
                      (blank p)
                      (if (or (at? p ".") (at? p "["))
                          (table.insert segs (segment p))
                          (do
                            (set p.i save)
                            (set more false)))))
                  segs)))

(local cache (setmetatable {} {:__mode :v}))

(fn compile [text]
  "The parsed form of JSONPath query text; raises \"invalid JSONPath query:
…\" for anything RFC 9535 doesn't allow."
  (or (. cache text) (let [p {:s text :i 1}]
                       (when (not (utf8.len text))
                         (fail p "not UTF-8"))
                       (when (not (at? p "$"))
                         (fail p "expected $"))
                       (let [q (query p)]
                         (when (<= p.i (length text))
                           (fail p "unexpected text"))
                         (tset cache text q)
                         q))))

;; ---- evaluation ----

(var select-nodes nil)

(fn equal? [a b]
  (if (or (= a nothing) (= b nothing)) (= a b)
      (and (= (type a) :number) (= (type b) :number)) (= a b)
      (and (array? a) (array? b))
      (and (= (length a) (length b))
           (accumulate [ok true i x (ipairs a) &until (not ok)]
             (equal? x (. b i)))) (and (object? a) (object? b))
      (let [keys-a (sorted-keys a)
            keys-b (sorted-keys b)]
        (and (= (length keys-a) (length keys-b))
             (accumulate [ok true i k (ipairs keys-a) &until (not ok)]
               (and (= k (. keys-b i)) (equal? (. a k) (. b k))))))
      (= a b)))

(fn less? [a b]
  ;; strings by code point: UTF-8 bytes keep that order
  (or (and (= (type a) :number) (= (type b) :number) (< a b))
      (and (= (type a) :string) (= (type b) :string) (< a b))))

(var call nil)

(fn comparable-value [node root current]
  (match node.kind
    :literal node.value
    :query (let [nodes (select-nodes node root current)]
             (if (= 1 (length nodes)) (. nodes 1 :value) nothing))
    :function (call node root current)))

(fn logical? [node root current]
  (match node.op
    :exists (if (= node.query.kind :function)
                (> (length (call node.query root current)) 0)
                (> (length (select-nodes node.query root current)) 0))
    :call (call node.call root current)
    :not (not (logical? node.expr root current))
    :and (and (logical? node.left root current)
              (logical? node.right root current))
    :or (or (logical? node.left root current)
            (logical? node.right root current))
    :compare (let [a (comparable-value node.left root current)
                   b (comparable-value node.right root current)]
               (match node.cmp
                 "==" (equal? a b)
                 "!=" (not (equal? a b))
                 "<" (less? a b)
                 "<=" (or (less? a b) (equal? a b))
                 ">" (less? b a)
                 ">=" (or (less? b a) (equal? a b))))))

(fn regex-test [text pattern anywhere]
  (if (and (= (type text) :string) (= (type pattern) :string))
      (let [(ok prog) (pcall iregexp.compile pattern)]
        (and ok (if anywhere (iregexp.search? prog text)
                    (iregexp.matches? prog text))))
      false))

(set call
     (fn [node root current]
       ;; each argument as its parameter takes it: a value (a singular
       ;; query's, or Nothing), nodes, or a logical value
       (let [arg #(let [a (. node.args $)]
                    (match (. functions node.name :params $)
                      :nodes (select-nodes a root current)
                      :logical (logical? (if (= a.kind :logical) a
                                             {:kind :logical
                                              :op :exists
                                              :query a})
                                         root current)
                      _ (comparable-value a root current)))]
         (match node.name
           :length (let [v (arg 1)]
                     (if (= (type v) :string) (utf8.len v)
                         (array? v) (length v)
                         (object? v) (length (sorted-keys v))
                         nothing))
           :count (length (arg 1))
           :match (regex-test (arg 1) (arg 2) false)
           :search (regex-test (arg 1) (arg 2) true)
           :value (let [nodes (arg 1)]
                    (if (= 1 (length nodes)) (. nodes 1 :value) nothing))))))

(fn child [node key value]
  (let [path (icollect [_ k (ipairs node.path)] k)]
    (table.insert path key)
    {: value : path}))

(fn children [node]
  "The child nodes of node, arrays in order, objects by sorted name."
  (let [v node.value]
    (if (array? v) (icollect [i x (ipairs v)] (child node (- i 1) x))
        (object? v) (icollect [_ k (ipairs (sorted-keys v))]
                      (child node k (. v k)))
        [])))

(fn slice [node sel out]
  (let [v node.value
        len (length v)
        step (or sel.step 1)
        normalize #(if (>= $ 0) $ (+ len $))]
    (when (not= step 0)
      (let [start (normalize (or sel.start (if (> step 0) 0 (- len 1))))
            end (normalize (or sel.end (if (> step 0) len (- -1 len))))]
        (if (> step 0)
            (let [lower (math.min (math.max start 0) len)
                  upper (math.min (math.max end 0) len)]
              (var i lower)
              (while (< i upper)
                (table.insert out (child node i (. v (+ i 1))))
                (set i (+ i step))))
            (let [upper (math.min (math.max start -1) (- len 1))
                  lower (math.min (math.max end -1) (- len 1))]
              (var i upper)
              (while (< lower i)
                (table.insert out (child node i (. v (+ i 1))))
                (set i (+ i step)))))))))

(fn apply-selector [sel node root out]
  (let [v node.value]
    (match sel.kind
      :name (when (and (object? v) (not= nil (. v sel.name)))
              (table.insert out (child node sel.name (. v sel.name))))
      :wildcard (each [_ c (ipairs (children node))]
                  (table.insert out c))
      :index (when (array? v)
               (let [i (if (>= sel.index 0) sel.index (+ (length v) sel.index))]
                 (when (and (>= i 0) (< i (length v)))
                   (table.insert out (child node i (. v (+ i 1)))))))
      :slice (when (array? v)
               (slice node sel out))
      :filter (each [_ c (ipairs (children node))]
                (when (logical? sel.expr root c.value)
                  (table.insert out c))))))

(fn descendants [node out]
  "node, then each of its descendants, nodes before their children."
  (table.insert out node)
  (each [_ c (ipairs (children node))]
    (descendants c out))
  out)

(set select-nodes (fn [q root current]
                    (var nodes [{:value (if q.root root current) :path []}])
                    (each [_ seg (ipairs q.segments)]
                      (let [out []]
                        (each [_ node (ipairs nodes)]
                          (each [_ target (ipairs (if seg.descendant
                                                      (descendants node [])
                                                      [node]))]
                            (each [_ sel (ipairs seg.selectors)]
                              (apply-selector sel target root out))))
                        (set nodes out)))
                    nodes))

(fn query-nodes [text value]
  "The nodes JSONPath query text selects in value, as [{:value :path}], path
a list of member names and 0-based indexes."
  (select-nodes (compile text) value value))

(local control-escapes {"\b" "\\b" "\f" "\\f" "\n" "\\n" "\r" "\\r" "\t" "\\t"})

(fn escape-string [text delimiter]
  "text as the inside of a string literal between delimiter (' or \"), with
the escapes RFC 9535 prescribes: backslash, delimiter, and control
characters (\\b \\f \\n \\r \\t, else \\uXXXX)."
  (pick-values 1
               (text:gsub (.. "[%z\1-\31\\" delimiter "]")
                          #(if (or (= $ "\\") (= $ delimiter)) (.. "\\" $)
                               (or (. control-escapes $)
                                   (string.format "\\u%04x" (string.byte $)))))))

(fn normalized-path [path]
  "The normalized path (RFC 9535 section 2.7) of a list of names and indexes:
$['a'][0]."
  (.. "$" (table.concat (icollect [_ k (ipairs path)]
                          (if (= (type k) :number)
                              (.. "[" k "]")
                              (.. "['" (escape-string k "'") "']"))))))

{: compile :query query-nodes : normalized-path : escape-string : nothing}
