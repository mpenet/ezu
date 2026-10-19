;; ABOUTME: The MCP server of ezu mcp: operations as tools with JSON Schema
;; ABOUTME: 2020-12 inputs, and JSON-RPC over stdio for modern and legacy clients.
(local json (require :ezu.json))
(local http (require :ezu.http))
(local validate (require :ezu.validate))
(local arazzo (require :ezu.arazzo))
(local commands (require :ezu.arazzo.commands))

(fn object? [v]
  (and (= (type v) :table) (not= v json.null) (not (json.array? v))))

(fn check-arguments [arguments]
  "Raise unless a tool call's arguments are an object."
  (when (not (object? arguments))
    (error "arguments must be an object" 0)))

;; ---- schemas ----

;; keywords whose value is a schema, a list of schemas, or a map of them; any
;; other keyword is data (enum, example, default, …) and is copied as is
(local schema-keywords {:items true
                        :additionalItems true
                        :additionalProperties true
                        :contains true
                        :contentSchema true
                        :else true
                        :if true
                        :not true
                        :propertyNames true
                        :then true
                        :unevaluatedItems true
                        :unevaluatedProperties true})

(local schema-lists {:allOf true :anyOf true :oneOf true :prefixItems true})

(local schema-maps {:properties true
                    :patternProperties true
                    :dependentSchemas true
                    "$defs" true
                    :definitions true})

;; keywords that would change what the #/$defs/… references point at, or
;; restate the dialect: the tool's schema is one 2020-12 document
(local dropped-keywords {"$id" true
                         "$anchor" true
                         "$dynamicAnchor" true
                         "$schema" true})

(fn copy-data [v seen]
  "A copy of v, data inside a schema: a table inside itself, which JSON can't
hold, becomes null."
  (if (or (not= (type v) :table) (= v json.null)) v (. seen v) json.null
      (let [out (setmetatable {} (getmetatable v))]
        (tset seen v true)
        (each [k x (pairs v)]
          (tset out k (copy-data x seen)))
        (tset seen v nil)
        out)))

;; keywords that describe without constraining
(local annotations {:title true
                    :description true
                    :default true
                    :example true
                    :examples true
                    :deprecated true
                    :readOnly true
                    :writeOnly true
                    :externalDocs true
                    :xml true})

(fn constrains? [schema]
  "Whether schema has a keyword that limits what it allows."
  (accumulate [found false k (pairs schema) &until found]
    (not (or (. annotations k) (k:match "^x%-")))))

(fn openapi-30-keywords [out]
  "out with OpenAPI 3.0's nullable and boolean exclusive bounds written as
JSON Schema 2020-12 has them."
  (let [nullable (= out.nullable true)]
    (set out.nullable nil)
    (each [_ [bound exclusive] (ipairs [[:minimum :exclusiveMinimum]
                                        [:maximum :exclusiveMaximum]])]
      (when (= (type (. out exclusive)) :boolean)
        (if (and (. out exclusive) (not= nil (. out bound)))
            (do
              (tset out exclusive (. out bound))
              (tset out bound nil))
            (tset out exclusive nil))))
    (if (not nullable) out (= (type out.type) :string)
        (do
          (set out.type [out.type :null])
          (when (json.array? out.enum)
            (table.insert out.enum json.null))
          out)
        ;; nullable next to allOf, oneOf…: what they allow, or null
        (and (= nil out.type) (= nil out.enum) (constrains? out))
        {:anyOf [out {:type :null}]} out)))

(fn new-context []
  "Conversion state shared by the schemas of one tool: the $defs written for
recursive schemas, by schema."
  {:defs {} :ids {} :count 0})

(fn convert [schema openapi-30 ctx ancestors]
  (if (or (not= (type schema) :table) (= schema json.null)) schema
      (. ancestors schema)
      ;; a schema inside itself: a reference to its $defs entry
      (let [id (or (. ctx.ids schema)
                   (do
                     (set ctx.count (+ ctx.count 1))
                     (tset ctx.ids schema (.. "s" ctx.count))
                     (. ctx.ids schema)))]
        {"$ref" (.. "#/$defs/" id)})
      (let [out (setmetatable {} (getmetatable schema))
            sub #(convert $ openapi-30 ctx ancestors)
            ;; what is sent leaves out what only the server sets
            read-only (if ctx.request (validate.read-only-names schema) {})]
        (tset ancestors schema true)
        (each [k v (pairs schema)]
          (when (not (. dropped-keywords k))
            (tset out k (if (and (. schema-keywords k) (json.array? v))
                            (json.array (icollect [_ s (ipairs v)] (sub s)))
                            (. schema-keywords k)
                            (sub v)
                            (and (. schema-lists k) (= (type v) :table))
                            (json.array (icollect [_ s (ipairs v)] (sub s)))
                            (and (. schema-maps k) (= (type v) :table))
                            (collect [name s (pairs v)]
                              (when (not (and (= k :properties)
                                              (. read-only name)))
                                (values name (sub s))))
                            ;; draft 4-7: written as 2020-12 has it, below
                            (and (= k :dependencies) (= (type v) :table))
                            nil
                            (and (= k :required) (json.array? v)
                                 (next read-only))
                            (json.array (icollect [_ name (ipairs v)]
                                          (when (not (. read-only name)) name)))
                            ;; data: copied, so the result never shares tables with
                            ;; the spec
                            (copy-data v {})))))
        ;; dependencies: the names a property needs, or a schema
        (when (= (type schema.dependencies) :table)
          (each [name d (pairs schema.dependencies)]
            (let [[k value] (if (json.array? d)
                                [:dependentRequired (copy-data d {})]
                                [:dependentSchemas (sub d)])]
              (when (= nil (. out k))
                (tset out k {}))
              (tset (. out k) name value))))
        (tset ancestors schema nil)
        (let [out (if openapi-30 (openapi-30-keywords out) out)
              id (. ctx.ids schema)]
          (when (and id (= nil (. ctx.defs id)))
            ;; a copy: the entry must not hold the $defs it is in
            (tset ctx.defs id (collect [k v (pairs out)] k v)))
          out))))

(fn json-schema [schema openapi-30 ?ctx ?request]
  "schema (an OpenAPI schema with its refs resolved) as JSON Schema 2020-12,
the dialect of MCP tool schemas: OpenAPI 3.0's own keywords when openapi-30,
and recursion as references to $defs. ?request: schema describes what is
sent (a request body), so its read-only properties are left out. With ?ctx
(see new-context), the $defs are left in it for the caller to place at the
root of the document; without, they are added to the result."
  (let [ctx (or ?ctx (new-context))
        _ (set ctx.request ?request)
        out (convert schema openapi-30 ctx {})]
    (when (and (not ?ctx) (next ctx.defs) (= (type out) :table))
      (tset out "$defs" ctx.defs))
    out))

;; ---- tools ----

(local read-only-methods {:GET true :HEAD true :OPTIONS true})
(local destructive-methods {:DELETE true :PUT true :PATCH true})
(local idempotent-methods {:GET true
                           :HEAD true
                           :OPTIONS true
                           :PUT true
                           :DELETE true})

(fn param-schema [p]
  "A parameter's schema: its schema, or that of its content."
  (or p.schema (when (= (type p.content) :table)
                 (let [(_ media) (next p.content)]
                   (?. media :schema))) {}))

(fn tool-params [op opts]
  "The arguments of op's tool: [{:arg :in :name :schema :required
:description}], path parameters first; a name already taken (by another
parameter, or body) is prefixed with its location. Headers and query
parameters ezu adds itself (opts.supplied-headers, lower case, and
opts.supplied-query) are left out."
  (let [taken {}
        params []
        add (fn [p]
              (let [arg (if (. taken p.name) (.. p.in "." p.name) p.name)]
                (tset taken arg true)
                (table.insert params
                              {: arg
                               :in p.in
                               :name p.name
                               :schema (param-schema p)
                               :required (or p.required (= p.in :path))
                               :description p.description})))
        declared (or op.parameters [])
        supplied? (fn [p]
                    (or (and (= p.in :header)
                             (?. opts :supplied-headers (p.name:lower)))
                        (and (= p.in :query) (?. opts :supplied-query p.name))))]
    (when op.has-body
      (tset taken :body true))
    (each [_ name (ipairs op.path-params)]
      (add (or (accumulate [found nil _ p (ipairs declared) &until found]
                 (when (and (= p.in :path) (= p.name name)) p))
               {: name :in :path})))
    (each [_ location (ipairs [:query :header])]
      (each [_ p (ipairs declared)]
        (when (and (= p.in location) (not (supplied? p)))
          (add p))))
    params))

(fn annotations [method]
  {:readOnlyHint (= true (. read-only-methods method))
   :destructiveHint (= true (. destructive-methods method))
   :idempotentHint (= true (. idempotent-methods method))
   ;; the API is outside ezu
   :openWorldHint true})

(fn tool-description [op]
  (let [summary op.spec.summary
        description op.spec.description
        parts [(.. (op.method:upper) " " op.path)]]
    (each [_ text (ipairs [summary description])]
      (when (and (= (type text) :string) (not= text "")
                 (not= text (. parts (length parts))))
        (table.insert parts text)))
    (table.concat parts "\n\n")))

(fn tool [op opts]
  "The MCP tool definition of operation op. opts: {:openapi-30 bool
:supplied-headers {lower-case-name true} :supplied-query {name true}}"
  (let [ctx (new-context)
        properties {}
        required []]
    (each [_ p (ipairs (tool-params op opts))]
      (let [schema (json-schema p.schema opts.openapi-30 ctx)]
        (when (and p.description (= (type schema) :table)
                   (= nil schema.description))
          (set schema.description p.description))
        (tset properties p.arg schema)
        (when p.required
          (table.insert required p.arg))))
    (when op.has-body
      (tset properties :body
            (json-schema (or op.body-schema {}) opts.openapi-30 ctx true))
      (when (?. op.spec :requestBody :required)
        (table.insert required :body)))
    (table.sort required)
    (let [input {:type :object : properties :additionalProperties false}]
      (when (next required)
        (set input.required required))
      (when (next ctx.defs)
        (tset input "$defs" ctx.defs))
      {:name op.name
       :title op.spec.summary
       :description (tool-description op)
       :inputSchema input
       :annotations (annotations (op.method:upper))})))

(fn workflow-tool [wf inputs-schema ?words]
  "The MCP tool definition of Arazzo workflow wf, whose inputs (JSON Schema,
refs resolved) are inputs-schema, named by its command ?words, else its id."
  (let [parts [(.. "Arazzo workflow " wf.workflowId)]
        name (if ?words (table.concat ?words "_") wf.workflowId)]
    (each [_ text (ipairs [wf.summary wf.description])]
      (when (and (= (type text) :string) (not= text ""))
        (table.insert parts text)))
    {:name (.. "workflow." (pick-values 1 (name:gsub "[^%w_.-]" "_")))
     :title wf.summary
     :description (table.concat parts "\n\n")
     :inputSchema (if (= (type inputs-schema) :table)
                      (json-schema inputs-schema false)
                      {:type :object :additionalProperties false})
     ;; what a workflow does is up to its steps
     :annotations {:readOnlyHint false
                   :destructiveHint true
                   :idempotentHint false
                   :openWorldHint true}}))

(fn sorted-words [node]
  (doto (icollect [w (pairs node.children)] w)
    (table.sort)))

(fn command-workflows [doc load]
  "The workflows ezu mcp offers of doc, loading the documents it mounts with
(load doc source): [{:workflow :doc :words}], doc being the one the workflow
is in. With command words, those the words reach, mounted documents included,
by words: helpers without words are left out, and a mounted document without
command words offers its workflows by id. Without, doc's workflows, without
words. A document mounted inside itself is offered once."
  (if (not (commands.commands? doc))
      (icollect [_ wf (ipairs (or doc.workflows []))]
        {:workflow wf : doc})
      (let [found []
            add-mounted (fn [mounted words]
                          (each [_ wf (ipairs (or mounted.workflows []))]
                            (table.insert found
                                          {:workflow wf
                                           :doc mounted
                                           :words (doto (icollect [_ w (ipairs words)]
                                                          w)
                                                    (table.insert (tostring wf.workflowId)))})))]
        (fn walk [node words seen]
          (each [_ w (ipairs (sorted-words node))]
            (let [child (. node.children w)
                  words (doto (icollect [_ x (ipairs words)] x)
                          (table.insert w))]
              (if child.mount
                  (let [mounted (load child.doc child.mount)
                        here (or (arazzo.location mounted) mounted)]
                    (when (not (. seen here))
                      (if (commands.commands? mounted)
                          (walk (. (commands.resolve mounted [] load) :node)
                                words
                                (doto (collect [k v (pairs seen)] k v)
                                  (tset here true)))
                          (add-mounted mounted words))))
                  (do
                    (when child.workflow
                      (table.insert found
                                    {:workflow child.workflow
                                     :doc child.doc
                                     : words}))
                    (walk child words seen))))))

        (walk (. (commands.resolve doc [] load) :node) []
              {(or (arazzo.location doc) doc) true})
        found)))

(fn argument-errors [op params arguments]
  "Required arguments missing, and parameter values their schemas refuse."
  (let [errors []]
    (each [_ p (ipairs params)]
      (let [v (. arguments p.arg)]
        (if (not= nil v)
            (each [_ e (ipairs (validate.check p.schema v p.arg))]
              (table.insert errors e))
            p.required
            (table.insert errors (.. "missing required argument: " p.arg)))))
    (when (and op.has-body (?. op.spec :requestBody :required)
               (= nil arguments.body))
      (table.insert errors "missing required argument: body"))
    errors))

(fn request [op arguments ?opts]
  "The op.invoke request for a tool call's arguments; raises for arguments
the tool doesn't take, missing ones, and parameter values their schemas
refuse."
  (check-arguments arguments)
  (let [params (tool-params op (or ?opts {}))
        by-arg (collect [_ p (ipairs params)] p.arg p)
        req {:path {} :query {} :headers {}}]
    (each [arg v (pairs arguments)]
      (if (and (= arg :body) op.has-body) (set req.body v)
          (let [p (or (. by-arg arg) (error (.. "unknown argument: " arg) 0))]
            (match p.in
              :path (tset req.path p.name v)
              :query (tset req.query p.name v)
              :header (tset req.headers p.name v)))))
    (let [errors (argument-errors op params arguments)]
      (when (next errors)
        (error (table.concat errors "\n") 0)))
    {:path req.path
     :query (when (next req.query) req.query)
     :headers (when (next req.headers) req.headers)
     ;; a JSON string, number or null is sent as JSON, not as the body's text
     :body (if (and (not= nil req.body) (not (object? req.body))
                    (not (json.array? req.body))
                    (http.json-type? op.content-type))
               (json.encode req.body)
               req.body)}))

;; ---- protocol ----

(local modern-versions ["2026-07-28"])

;; protocol versions that open with initialize, the latest first
(local legacy-versions ["2025-11-25" "2025-06-18" "2025-03-26" "2024-11-05"])

(local all-versions (let [all []]
                      (each [_ versions (ipairs [modern-versions
                                                 legacy-versions])]
                        (each [_ v (ipairs versions)]
                          (table.insert all v)))
                      all))

(local meta-version "io.modelcontextprotocol/protocolVersion")
(local meta-capabilities "io.modelcontextprotocol/clientCapabilities")
(local meta-server-info "io.modelcontextprotocol/serverInfo")

(fn member? [list x]
  (accumulate [found false _ v (ipairs list) &until found]
    (= v x)))

(fn valid-id? [id]
  "MCP request ids are strings or integers."
  (or (= (type id) :string) (= (math.type id) :integer)))

;; lists clients may cache, for as long as ezu runs with the profile they
;; were made for; no telling how long that is
(local cache-hints {:ttlMs 0 :cacheScope :private})

(fn error-response [id code message ?data]
  {:jsonrpc "2.0"
   :id (if (= nil id) json.null id)
   :error {: code : message :data ?data}})

(fn handler [server]
  "A function answering one decoded JSON-RPC message: a response, or nil for
notifications. Requests carrying a modern protocol version in _meta are served
statelessly (2026-07-28); initialize opens the legacy protocol for the rest of
the process. server: {:tools [tool] :call (fn [name arguments] result)
:version :instructions}"
  (var legacy false)
  (let [by-name (collect [_ t (ipairs server.tools)] t.name t)
        server-info {:name "ezu" :version server.version}
        results {"server/discover" (fn [modern]
                                     (when modern
                                       {:supportedVersions (json.array modern-versions)
                                        :capabilities {:tools {}}
                                        :instructions server.instructions
                                        :ttlMs cache-hints.ttlMs
                                        :cacheScope cache-hints.cacheScope}))
                 "tools/list" #(doto {:tools (json.array server.tools)}
                                 (tset :ttlMs (when $1 cache-hints.ttlMs))
                                 (tset :cacheScope
                                       (when $1 cache-hints.cacheScope)))
                 "tools/call" (fn [_ params]
                                (if (. by-name params.name)
                                    (server.call params.name
                                                 ;; null is no arguments
                                                 (if (or (= nil
                                                            params.arguments)
                                                         (= json.null
                                                            params.arguments))
                                                     {}
                                                     params.arguments))
                                    (values nil -32602
                                            (.. "Unknown tool: "
                                                (tostring params.name)))))
                 :ping #{}}
        respond (fn [msg modern]
                  (let [params (if (= (type msg.params) :table) msg.params {})
                        result-fn (. results msg.method)
                        (result code message) (when result-fn
                                                (result-fn modern params))]
                    (if result
                        {:jsonrpc "2.0"
                         :id msg.id
                         :result (if modern
                                     (doto result
                                       (tset :resultType :complete)
                                       (tset :_meta
                                             {meta-server-info server-info}))
                                     result)}
                        code
                        (error-response msg.id code message)
                        (error-response msg.id -32601
                                        (.. "Method not found: " msg.method)))))]
    (fn [msg]
      (if (not (object? msg))
          (error-response nil -32600 "Invalid request")
          ;; responses: ezu asks nothing, so there is nothing to match
          (and (not= (type msg.method) :string)
               (or (not= nil msg.result) (not= nil msg.error)))
          nil
          (or (not= (type msg.method) :string)
              (and (not= nil msg.id) (not (valid-id? msg.id))))
          (error-response (when (valid-id? msg.id) msg.id) -32600
                          "Invalid request")
          ;; notifications
          (= nil msg.id)
          nil
          (not (or (= nil msg.params) (object? msg.params)))
          (error-response msg.id -32602 "params must be an object")
          (let [meta (?. msg :params :_meta)
                version (when (object? meta) (. meta meta-version))]
            (if version
                (if (not (member? modern-versions version))
                    (error-response msg.id -32022
                                    "Unsupported protocol version"
                                    {:supported (json.array all-versions)
                                     :requested version})
                    (not (object? (. meta meta-capabilities)))
                    (error-response msg.id -32602
                                    (.. "missing _meta " meta-capabilities))
                    (respond msg true))
                (= msg.method :initialize)
                (let [asked (?. msg :params :protocolVersion)]
                  (set legacy true)
                  {:jsonrpc "2.0"
                   :id msg.id
                   :result {:protocolVersion (if (member? legacy-versions asked)
                                                 asked
                                                 (. legacy-versions 1))
                            :capabilities {:tools {}}
                            :serverInfo server-info
                            :instructions server.instructions}})
                (or legacy (= msg.method :ping))
                (respond msg false)
                (error-response msg.id -32602
                                (.. "missing _meta " meta-version
                                    " (ezu speaks "
                                    (table.concat modern-versions ", ")
                                    ", or initialize for "
                                    (table.concat legacy-versions ", ") ")"))))))))

(fn valid-utf8 [s]
  "s with each byte that isn't part of valid UTF-8 replaced by U+FFFD."
  (if (utf8.len s) s (let [parts []]
                       (var from 1)
                       (var (ok bad) (utf8.len s))
                       (while (not ok)
                         (table.insert parts (s:sub from (- bad 1)))
                         (table.insert parts "\239\191\189")
                         (set from (+ bad 1))
                         (set (ok bad) (utf8.len s from)))
                       (table.insert parts (s:sub from))
                       (table.concat parts))))

(fn answer [handle msg]
  "handle's response to msg, an internal error when it fails."
  (let [(ok response) (pcall handle msg)]
    (if ok response
        (error-response (when (and (object? msg) (valid-id? msg.id)) msg.id)
                        -32603 (tostring response)))))

(fn serve [handle read-line write-line]
  "Answer the newline-delimited JSON-RPC messages read-line returns, until it
returns nil, writing each response with write-line (one line, no newline).
A batch (an array of messages) gets an array of responses."
  (var line (read-line))
  (while line
    (when (line:match "%S")
      (let [(ok msg) (pcall json.decode line true)
            response (if (not ok) (error-response nil -32700 "Parse error")
                         (and (json.array? msg) (not= nil (. msg 1)))
                         (let [responses (icollect [_ m (ipairs msg)]
                                           (answer handle m))]
                           (when (next responses)
                             (json.array responses)))
                         (json.array? msg)
                         (error-response nil -32600 "Invalid request")
                         (answer handle msg))]
        (when response
          ;; arguments and API responses may hold any bytes
          (write-line (valid-utf8 (json.encode response))))))
    (set line (read-line))))

{: json-schema
 : tool
 : workflow-tool
 : command-workflows
 : request
 : check-arguments
 : handler
 : serve}
