;; ABOUTME: Builds operation requests from parsed CLI arguments: body reading
;; ABOUTME: and decoding, typed body fields, multipart files, pre-send checks.
(local coerce (require :ezu.coerce))
(local validate (require :ezu.validate))
(local util (require :ezu.util))
(local yaml (require :ezu.yaml))
(local json (require :ezu.json))

(fn read-file [path]
  (let [f (assert (io.open path :rb))
        content (f:read :*a)]
    (f:close)
    content))

(fn read-body [s]
  "Raw body text: inline, @path for a file, @- for stdin."
  (if (= s "@-") (io.read :*a)
      (s:match "^@(.+)") (read-file (s:match "^@(.+)"))
      s))

(fn decode-structured [raw]
  ;; null members are kept: the body is sent as given
  (let [(ok parsed) (pcall yaml.decode raw true)]
    (assert (and ok (not= nil parsed))
            (.. "invalid body (expected JSON or YAML): " (tostring parsed)))
    parsed))

(fn media-type [op]
  "op's request media type in lower case (media types ignore case), or nil."
  (when op.content-type
    (op.content-type:lower)))

(fn decode-body [raw content-type]
  "Decode a raw body for an operation's content type: JSON, form and
multipart operations take JSON or YAML; any other type is sent as-is."
  (if (or (= nil content-type) (: content-type :match "json")
          (: content-type :match "^application/x%-www%-form%-urlencoded")
          (: content-type :match "^multipart/form%-data"))
      (decode-structured raw)
      raw))

(fn set-nested [t keys v]
  (var cur t)
  (for [i 1 (- (length keys) 1)]
    (let [k (. keys i)]
      (when (or (not= (type (. cur k)) :table) (= (. cur k) json.null))
        (tset cur k {}))
      (set cur (. cur k))))
  (tset cur (. keys (length keys)) v))

(fn build-body [fields ?schema ?base]
  "Apply [KEY.PATH VAL] fields onto ?base, coercing each value by ?schema. A
field whose schema is an array adds an item, typed by its items schema, to a
list the fields start (a value written as a JSON array is the whole list)."
  (assert (or (= ?base nil)
              (and (= (type ?base) :table) (not= ?base json.null)
                   (not (json.array? ?base))))
          "--body.KEY=VAL fields require --body to be a JSON object")
  (let [body (or ?base {})
        ;; the lists fields started: repeats add to them, not to ?base's
        lists {}]
    (each [_ [path v] (ipairs fields)]
      (let [keys (icollect [k (path:gmatch "[^.]+")] k)
            schema (coerce.schema-at ?schema keys)]
        (when (= nil (. keys 1))
          (error (.. "field path '" path "' has no field name") 0))
        (if (and (= (coerce.type-of schema) "array") (not (v:match "^%s*%[")))
            (let [item (coerce.from-string v (?. schema :items))]
              (if (. lists path)
                  (table.insert (. lists path) item)
                  (let [list (json.array [item])]
                    (tset lists path list)
                    (set-nested body keys list))))
            (set-nested body keys (coerce.from-string v schema)))))
    body))

(fn file-part [value]
  "Multipart value for a CLI field: @path reads a file part, @@ escapes @."
  (if (and (= (type value) :string) (value:match "^@@"))
      (value:sub 2)
      (and (= (type value) :string) (value:match "^@(.+)"))
      (let [path (value:sub 2)]
        {:filename (path:match "[^/]+$") :content (read-file path)})
      value))

(fn decode-json-params [op query]
  "query with the values of parameters declared with JSON content decoded
from the JSON text given on the command line, so it isn't encoded twice."
  (collect [name v (pairs query)]
    (let [json? (accumulate [found false _ param (ipairs (or op.parameters []))
                             &until found]
                  (and (= param.in :query) (= param.name name)
                       (util.json-content? param)))
          _ (when (and json? (= (type v) :table))
              (error (.. "--q." name
                         " takes one JSON value (give a JSON array once for a list)")
                     0))
          (ok decoded) (if (and json? (= (type v) :string))
                           (pcall json.decode v)
                           false)]
      (values name (if ok decoded v)))))

(fn op-request [op p]
  "Build an op.invoke request from parsed CLI args."
  (when (and (not op.has-body) (or (not= nil p.body) (next p.body-fields)))
    (error (.. op.name " takes no request body") 0))
  (let [json-op? (and op.content-type (: (media-type op) :match "json"))
        valid-json? #(pcall json.decode $)
        given (if (not= (type p.body) :string) p.body
                  ;; valid JSON goes out byte-for-byte: scalars, null and
                  ;; number formatting survive
                  (and json-op? (not (next p.body-fields)) (valid-json? p.body))
                  p.body (let [v (decode-body p.body (media-type op))]
                          (if (and json-op? (not= (type v) :table))
                              (json.encode v)
                              v)))
        multipart? (and op.content-type
                        (: (media-type op) :match "^multipart/form%-data"))
        body (if (next p.body-fields)
                 (let [b (build-body p.body-fields op.body-schema given)]
                   (if multipart?
                       (collect [k v (pairs b)] k (file-part v))
                       b))
                 given)]
    {:path (collect [i name (ipairs op.path-params)] name (. p.path-params i))
     :query (when (next p.query) (decode-json-params op p.query))
     :headers (when (next p.headers) p.headers)
     :body (when op.has-body body)}))

(fn check-params [op request]
  "Check request query/headers against the operation's declared parameters.
Returns (errors warnings): missing required params are errors, undeclared
query names are warnings. Header names match case-insensitively;
request.implied-query names the query parameters added on the way (profile
query, query API key), present but not given."
  (let [errors []
        warnings []
        declared-query {}]
    (each [_ param (ipairs (or op.parameters []))]
      (match param.in
        :query (do
                 (tset declared-query param.name true)
                 (when (and param.required
                            (= nil (?. request :query param.name))
                            (not (?. request :implied-query param.name)))
                   (table.insert errors
                                 (string.format "missing required query parameter '%s' (--q.%s=…)"
                                                param.name param.name))))
        :header (when (and param.required
                           (= nil (util.header request.headers param.name)))
                  (table.insert errors
                                (string.format "missing required header '%s' (--h.%s=…)"
                                               param.name param.name)))))
    (let [declared (doto (icollect [n (pairs declared-query)] n)
                     (table.sort))
          given (doto (icollect [n (pairs (or request.query {}))]
                        n)
                  (table.sort))]
      (each [_ name (ipairs given)]
        (when (not (. declared-query name))
          (table.insert warnings
                        (string.format "%s does not declare query parameter '%s' (declared: %s)"
                                       op.name name
                                       (if (= 0 (length declared)) "none"
                                           (table.concat declared ", ")))))))
    (values errors warnings)))

(fn check-body [op body]
  "Schema errors for a JSON operation's body (decoded table or JSON text)."
  (if (or (= nil body) (not op.body-schema) (not op.content-type)
          (not (: (media-type op) :match "json")))
      []
      (let [(ok value) (if (= (type body) :string)
                           (pcall json.decode body true)
                           (values true body))]
        (if ok (validate.check op.body-schema value :body) []))))

(fn declared-response [responses status]
  "(key response) of what responses declares for status: the status itself,
its range (4XX), or default."
  (let [code (tostring status)
        range (.. (code:sub 1 1) "XX")]
    (accumulate [found nil _ key (ipairs [code range (range:lower) :default])
                 &until found]
      (when (. responses key)
        [key (. responses key)]))))

(fn media-type [content-type]
  (when content-type
    (: (: content-type :match "^[^;]*") :lower)))

(fn declared-media-type [content content-type]
  "The key of content matching content-type: itself, type/*, or */*."
  (let [mt (media-type content-type)]
    (when mt
      (accumulate [found nil _ key (ipairs [mt
                                            (.. (mt:match "^[^/]*") "/*")
                                            "*/*"])
                   &until found]
        (accumulate [hit nil declared (pairs content) &until hit]
          (when (= (media-type declared) key) declared))))))

(fn check-response [op resp]
  "How resp differs from what op's spec declares: an undeclared status or
content type, or a body its schema doesn't allow (checked as a response:
read-only properties may be required, write-only ones aren't)."
  (let [name (or op.operation-id op.name "the operation")
        responses (or (?. op :spec :responses) {})
        found (declared-response responses resp.status)]
    (if (not found)
        [(string.format "status %s is not among the responses %s declares"
                        (tostring resp.status) name)]
        (let [[key declared] found
              content (?. declared :content)
              content-type (util.header (or resp.headers {}) "content-type")]
          (if (or (not= (type content) :table) (= nil (next content))
                  (= nil resp.body))
              []
              (let [mt (declared-media-type content content-type)]
                (if (not mt)
                    [(string.format "content type %s is not one %s declares for %s (%s)"
                                    (tostring (media-type content-type)) name
                                    key
                                    (table.concat (doto (icollect [k (pairs content)]
                                                          k)
                                                    (table.sort))
                                                  ", "))]
                    ;; only decoded bodies (JSON, YAML) are checked
                    (let [schema (?. content mt :schema)]
                      (if (and schema (not= (type resp.body) :string))
                          (validate.check schema resp.body :response :response)
                          [])))))))))

{: read-file
 : read-body
 : decode-structured
 : decode-body
 : set-nested
 : build-body
 : file-part
 : op-request
 : check-params
 : check-body
 : check-response}
