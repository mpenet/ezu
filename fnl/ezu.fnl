;; ABOUTME: Builds callable API clients from OpenAPI 3.x schemas at runtime;
;; ABOUTME: each operation is invocable positionally or with a structured request.
(local util (require :ezu.util))
(local refs (require :ezu.refs))
(local json (require :ezu.json))

(local negotiate (require :ezu.negotiate))

(local doc (require :ezu.doc))

(local yaml (require :ezu.yaml))

(local http (require :ezu.http))

(fn parse-schema [text location]
  "The document in text (JSON or YAML), which must be a mapping; location
names it in errors."
  (let [(ok parsed) (pcall yaml.decode text)]
    (assert ok
            (string.format "failed to parse schema from '%s': %s"
                           (util.redact-url location) (tostring parsed)))
    (assert (and (= (type parsed) :table) (not= parsed json.null)
                 (not (json.array? parsed)))
            (string.format "'%s' is not an OpenAPI document"
                           (util.redact-url location)))
    parsed))

(fn load-schema [path ?opts]
  "Load an OpenAPI schema (JSON or YAML) from a local file path or http(s):// URL.
?opts — {:ssl tls-options :headers {} :timeout seconds} for fetching a URL"
  (parse-schema (http.fetch-text path
                                 {:headers (?. ?opts :headers)
                                  :ssl (?. ?opts :ssl)
                                  :timeout (?. ?opts :timeout)})
                path))

(fn merge-headers [...]
  "Merge header tables left to right; names are lowercased so later
tables override earlier ones regardless of case."
  (let [out {}]
    (each [_ hs (ipairs [...])]
      (each [k v (pairs hs)]
        (tset out (k:lower) v)))
    out))

(fn op-summary [op-spec]
  (let [s op-spec.summary
        d op-spec.description]
    (if (and s (not= s "")) s
        (and d (not= d "")) d
        nil)))

(fn positional-request [op args]
  "The invoke request for a positional call: path params in template order,
then the body when the operation has one, then an opts table."
  (let [n-path (length op.path-params)
        opts (or (. args (+ n-path (if op.has-body 2 1))) {})]
    {:path (collect [i name (ipairs op.path-params)] name (. args i))
     :body (when op.has-body (. args (+ n-path 1)))
     :query opts.query
     :headers opts.headers
     :timeout opts.timeout}))

(local operation-mt {:__call (fn [op ...]
                               (op.invoke (positional-request op [...])))
                     ;; the REPL docstring is rendered on first access only
                     :__index (fn [op key]
                                (when (= key :fnl/docstring)
                                  (let [text (doc.build op.path op.method
                                                        op.spec op.name)]
                                    (rawset op key text)
                                    text)))})

(fn operation-url [base-url path req]
  ;; servers often end in / while paths start with one
  (.. (pick-values 1 (base-url:gsub "/+$" ""))
      (util.resolve-path path (or req.path {}))))

(fn make-operation [client-opts name path path-item method op-spec]
  (let [op-spec (doto (collect [k v (pairs op-spec)]
                        k
                        v)
                  (tset :parameters
                        (util.merge-parameters path-item.parameters
                                               op-spec.parameters)))
        ;; the declared media type (to find its schema), and what is sent
        declared-type (negotiate.pick-content-type op-spec)
        content-type (negotiate.wire-type declared-type)
        negotiated {:accept (negotiate.pick-accept op-spec)
                    :content-type content-type}
        ;; how each declared query parameter is serialized
        query-styles (collect [_ p (ipairs (or op-spec.parameters []))]
                       (when (= p.in :query)
                         (values p.name
                                 {:style p.style
                                  :explode p.explode
                                  ;; declared with content instead of schema
                                  :json (util.json-content? p)})))
        url-for (fn [?req]
                  "Full request URL for {:path {name v} :query {}}, or with
:querystring the whole query string as given."
                  (let [req (or ?req {})
                        url (operation-url client-opts.base-url path req)]
                    (if req.querystring (.. url "?" req.querystring)
                        (util.append-query url (or req.query {}) query-styles))))
        invoke (fn [?req]
                 "Call the operation with {:path {name v} :query {} :headers {} :body v :timeout n},
or :querystring for the whole query string (OpenAPI 3.2)."
                 (let [req (or ?req {})]
                   (client-opts.http-fn {:body req.body
                                         ;; no Content-Type without a body
                                         :headers (merge-headers (if (= nil
                                                                        req.body)
                                                                     {:accept negotiated.accept}
                                                                     negotiated)
                                                                 (or client-opts.headers
                                                                     {})
                                                                 (or req.headers
                                                                     {}))
                                         :method (method:upper)
                                         ;; a querystring is the whole query
                                         :query (when (not req.querystring)
                                                  req.query)
                                         : query-styles
                                         :ssl client-opts.ssl
                                         :timeout (or req.timeout
                                                      client-opts.timeout)
                                         :url (if req.querystring
                                                  (.. (operation-url client-opts.base-url
                                                                     path req)
                                                      "?" req.querystring)
                                                  (operation-url client-opts.base-url
                                                                 path req))})))
        param-names (util.extract-path-params path)]
    (setmetatable {:body-schema (?. op-spec :requestBody :content declared-type
                                    :schema)
                   :content-type content-type
                   :has-body (not= nil op-spec.requestBody)
                   : invoke
                   : method
                   : name
                   :operation-id op-spec.operationId
                   :parameters op-spec.parameters
                   : path
                   :path-params param-names
                   :spec op-spec
                   :summary (op-summary op-spec)
                   : url-for} operation-mt)))

(local http-methods {:get true
                     :put true
                     :post true
                     :delete true
                     :options true
                     :head true
                     :patch true
                     :trace true})

(fn schema-operations [schema deref]
  "The schema's operations as [{:path :path-item :method :op-spec}], with
their refs resolved, in path then method order, so that naming them is
deterministic."
  (let [paths (doto (icollect [path item (pairs (or schema.paths {}))]
                      ;; extensions (x-...) may hold any value
                      (when (= (type item) :table) path))
                (table.sort))
        entries []]
    (each [_ path (ipairs paths)]
      (let [path-item (deref (. schema.paths path))
            methods (doto (icollect [method op-spec (pairs path-item)]
                            (when (and (. http-methods method)
                                       (= (type op-spec) :table))
                              method))
                      (table.sort))]
        (each [_ method (ipairs methods)]
          (table.insert entries
                        {: path
                         : path-item
                         : method
                         :op-spec (. path-item method)}))))
    entries))

(fn ref-load-opts [load-opts source-url location]
  "Loader options for a document a $ref points to: the spec's headers and
credentials only go to the spec's own origin."
  (let [origin (when source-url (util.origin source-url))]
    (if (and origin (= origin (util.origin location)))
        load-opts
        {:ssl load-opts.ssl :timeout load-opts.timeout :credentials false})))

(fn sorted [items]
  (doto (icollect [_ x (ipairs items)] x)
    table.sort))

(fn expand-server-url [server overrides]
  "Server URL with {variables} replaced by overrides or their defaults.
Overrides must name declared variables and respect their enum."
  (let [variables (or server.variables {})]
    (each [name value (pairs overrides)]
      (let [spec (. variables name)]
        (when (not spec)
          (error (string.format "unknown server variable '%s' (known: %s)" name
                                (table.concat (sorted (icollect [k (pairs variables)]
                                                        k))
                                              ", ")) 0))
        (when (and spec.enum
                   (not (accumulate [found false _ allowed (ipairs spec.enum)
                                     &until found]
                          (= (tostring allowed) (tostring value)))))
          (error (string.format "server variable %s: '%s' is not one of %s"
                                name (tostring value)
                                (table.concat spec.enum ", "))
                 0))))
    (accumulate [url server.url name spec (pairs variables)]
      (util.replace-all url (.. "{" name "}")
                        (tostring (or (. overrides name) spec.default))))))

(fn servers [schema]
  "The schema's servers as [{:url :description :variables {name {:default :enum :description}}}]."
  (icollect [_ s (ipairs (or schema.servers []))]
    {:url s.url
     :description s.description
     :variables (collect [name v (pairs (or s.variables {}))]
                  name
                  {:default v.default :enum v.enum :description v.description})}))

(fn pick-server [schema index]
  "The schema's server at index; no servers means one at /, the spec's own
host (OpenAPI)."
  (let [servers (if (and (= (type schema.servers) :table)
                         (not= nil (. schema.servers 1)))
                    schema.servers
                    [{:url "/"}])]
    (assert (and (. servers index) ;; the default server at / is no choice
                 (or (= index 1) (not= nil (?. schema :servers 1))))
            (string.format "server index %s out of range (schema has %d servers)"
                           (tostring index) (length (or schema.servers []))))
    (. servers index)))

(fn resolve-server-url [server-url source-url]
  "An expanded server URL as an absolute one: relative ones are relative to
the spec's location."
  (or (when (server-url:match "^https?://")
        server-url)
      (when (and source-url (source-url:match "^https?://")
                 (server-url:match "^/"))
        ;; /path or //host/path
        (util.resolve-reference source-url server-url))
      (error "no base-url: schema servers URL is missing or unresolvable, pass :base-url in opts")))

(fn own-server [path-item op-spec index]
  "The server of an operation that declares its own (or whose path item
does): the one at the client's index, else its first."
  (let [list (or (?. op-spec :servers) (?. path-item :servers))]
    (when (and (= (type list) :table) (. list 1))
      (or (. list index) (. list 1)))))

(fn declared-vars [server server-vars]
  "The server-vars server declares: each server takes its own."
  (collect [k v (pairs server-vars)]
    (when (?. server :variables k) (values k v))))

(fn check-server-vars [server in-use server-vars]
  "Raise for a variable that none of the servers in use declares."
  (each [k (pairs server-vars)]
    (when (not (accumulate [found false _ s (ipairs in-use) &until found]
                 (not= nil (?. s :variables k))))
      ;; its error names the variables server knows
      (expand-server-url server server-vars))))

(fn schema-resolver [schema source-url ?opts]
  "schema's $ref resolver: documents it refers to are loaded with
?opts.load-schema (default load-schema), with ?opts.ssl, headers and timeout."
  (let [load-opts {:ssl (?. ?opts :ssl)
                   :headers (?. ?opts :headers)
                   :timeout (?. ?opts :timeout)}
        load (or (?. ?opts :load-schema) load-schema)]
    (refs.resolver schema
                   {:base source-url
                    :load #(load $ (ref-load-opts load-opts source-url $))})))

(fn servers-in-use [entries server index]
  "server and those the operations of entries declare."
  (doto (icollect [_ e (ipairs entries)]
          (own-server e.path-item e.op-spec index))
    (table.insert server)))

(fn base-url [schema ?opts]
  "The URL a client of schema sends requests to: ?opts.base-url, else the
server at ?opts.server-index (default 1) with its ?opts.server-vars applied,
relative to ?opts.source-url, the spec's location. Like a client, it takes
the variables of the servers operations declare.
?opts — {:base-url :server-index :server-vars :source-url}, and the client's
:load-schema :ssl :headers :timeout for documents the spec refers to"
  (or (?. ?opts :base-url)
      (let [index (or (?. ?opts :server-index) 1)
            server (pick-server schema index)
            server-vars (or (?. ?opts :server-vars) {})
            entries (schema-operations schema
                                       (schema-resolver schema
                                                        (?. ?opts :source-url)
                                                        ?opts))]
        (check-server-vars server (servers-in-use entries server index)
                           server-vars)
        (resolve-server-url (expand-server-url server
                                               (declared-vars server
                                                              server-vars))
                            (?. ?opts :source-url)))))

(fn client [schema ?opts]
  "Build an API client from an OpenAPI 3.x schema.

schema — parsed schema table, local file path, or http(s):// URL
?opts — {:base-url \"https://...\" :server-index n :server-vars {:name value} :headers {} :http-fn custom-fn
         :load-schema (fn [location {:ssl :headers :timeout}]) to fetch schema documents yourself}
base-url defaults to schema.servers[1].url with :server-vars applied"
  (let [source-url (or (when (= (type schema) :string)
                         schema) (?. ?opts :source-url))
        load-opts {:ssl (?. ?opts :ssl)
                   :headers (?. ?opts :headers)
                   :timeout (?. ?opts :timeout)}
        load (or (?. ?opts :load-schema) load-schema)
        schema (if (= (type schema) :string)
                   (load schema load-opts)
                   schema)
        ;; a document ezu fetched (or was told the location of) must say it
        ;; is a spec: an API answer or a config file is not one
        _ (when (and source-url
                     (not (or (?. schema :openapi) (?. schema :swagger))))
            (error (.. "'" (util.redact-url source-url)
                       "' is not an OpenAPI document (it has no \"openapi\" field)")
                   0))
        deref (schema-resolver schema source-url ?opts)
        index (or (?. ?opts :server-index) 1)
        server (when (not (?. ?opts :base-url))
                 (pick-server schema index))
        entries (schema-operations schema deref)
        server-vars (or (?. ?opts :server-vars) {})
        vars-for #(declared-vars $ server-vars)
        _ (when (and server (not (?. ?opts :base-url)))
            (check-server-vars server (servers-in-use entries server index)
                               server-vars))
        server-url (when (and server (not (?. ?opts :base-url)))
                     (expand-server-url server (vars-for server)))
        base-url (or (?. ?opts :base-url)
                     (resolve-server-url server-url source-url))
        client-opts {:base-url base-url
                     :headers (or (?. ?opts :headers) {})
                     :http-fn (or (?. ?opts :http-fn) http.request)
                     :ssl (?. ?opts :ssl)
                     :timeout (?. ?opts :timeout)}
        client {}
        ;; servers of the operation, else of its path item, replace the
        ;; client's unless :base-url was given
        operation-opts (fn [path-item op-spec]
                         (let [own (when (not (?. ?opts :base-url))
                                     (own-server path-item op-spec index))]
                           (if (not own) client-opts
                               (let [url (expand-server-url own (vars-for own))]
                                 (doto (collect [k v (pairs client-opts)] k v)
                                   (tset :base-url
                                         (if (url:match "^https?://") url
                                             (util.resolve-reference base-url
                                                                     url))))))))
        add (fn [name {: path : path-item : method : op-spec}]
              (tset client name
                    (make-operation (operation-opts path-item op-spec) name
                                    path path-item method op-spec)))
        unnamed (icollect [_ entry (ipairs entries)]
                  (let [name (when entry.op-spec.operationId
                               (util.operation-name entry.method entry.path
                                                    entry.op-spec))]
                    ;; an operationId of other scripts gives no name
                    (if (and name (not= name "") (= nil (. client name)))
                        (add name entry)
                        entry)))]
    ;; operations without an operationId, or whose name was taken, are named
    ;; after their method and path
    (each [_ entry (ipairs unnamed)]
      (let [base (util.operation-name entry.method entry.path {})]
        (var name base)
        (var n 1)
        (while (not= nil (. client name))
          (set n (+ n 1))
          (set name (.. base "-" n)))
        (add name entry)))
    client))

{:version "1.0.0-beta9"
 :client client
 :load-schema load-schema
 :parse-schema parse-schema
 :servers servers
 :server-url expand-server-url
 :base-url base-url}
