;; ABOUTME: The CLI option table and the argument parser driven by it; the
;; ABOUTME: same table feeds usage text and shell completion.
(local {: read-body : decode-structured} (require :ezu.cli.request))

(local field-prefixes ;; --PREFIX.NAME=VALUE families, long and short forms
       {:query :query
        :q :query
        :header :header
        :h :header
        :body :body
        :b :body
        :server :server
        :ssl :ssl})

(local options ;; :names        spellings accepted on the command line
       ;; :key          where the value goes in the parsed table
       ;; :value        nil for switches, else :number, :string, :body or :inputs
       ;; :positive     a :number that must be greater than 0
       ;; :arg          placeholder for the value in usage (default N or VALUE)
       ;; :shown        how usage displays it, when the default form doesn't fit
       ;; :scope        :op, :az, :auth or :any (op, az and http)
       ;; :also         other commands that take it
       ;; :explained    commands that refuse it with an explanation: parsed,
       ;;               but never offered
       ;; :family       a --PREFIX.NAME=VALUE family (its scope applies to all names)
       [{:names ["--list"] :key :list :scope :op :help "List all operations"}
        {:names ["--help"]
         :key :help
         :scope :any
         :also [:auth :profile]
         :help "Show documentation for an operation or workflow (or list them)"}
        {:names ["--body" "-d"]
         :key :body
         :value :body
         :shown "--body=JSON, -d JSON"
         :scope :op
         :also [:http]
         :help "Request body: inline JSON/YAML, @file or @- for stdin"}
        {:family "--b."
         :shown "--body.KEY=VAL"
         :scope :op
         :also [:http]
         :help "Body field, deep dot paths (short: --b.KEY=VAL)"}
        {:family "--q."
         :shown "--query.KEY=VAL"
         :scope :op
         :also [:http]
         :help "Query parameter; repeat for a list (short: --q.KEY=VAL)"}
        {:family "--h."
         :shown "--header.KEY=VAL"
         :scope :op
         :also [:http]
         :help "Request header (short: --h.KEY=VAL)"}
        {:names ["--timeout"]
         :key :timeout
         :value :number
         :positive true
         :scope :any
         :also [:mcp :auth]
         :help "Timeout in seconds"}
        {:names ["--check-response"]
         :key :check-response
         :scope :op
         :help "Report how the response differs from the spec, and fail"}
        {:names ["--until"]
         :key :until
         :value :string
         :arg "CONDITION"
         :scope :op
         :also [:http]
         :help "Send again until CONDITION holds, like $response.body#/state == 'ready'"}
        {:names ["--every"]
         :key :every
         :value :number
         :scope :op
         :also [:http]
         :help "Seconds between requests with --until (default: 5)"}
        {:names ["--max-time"]
         :key :max-time
         :value :number
         :scope :op
         :also [:http]
         :help "Seconds --until keeps trying (default: 600)"}
        {:names ["--max-pages"]
         :key :max-pages
         :value :number
         :scope :op
         :also [:mcp :http]
         :help "Max pages to follow via Link rel=next (default: 25)"}
        {:names ["--no-paginate"]
         :key :no-paginate
         :scope :op
         :also [:mcp :http]
         :help "Return only the first page"}
        {:names ["--retry"]
         :key :retry
         :value :number
         :scope :any
         :also [:mcp]
         :help "Retries for 408/429/5xx and network errors (default: 2)"}
        {:names ["--retry-unsafe"]
         :key :retry-unsafe
         :scope :any
         :also [:mcp]
         :help "Also retry POST/PUT/PATCH/DELETE"}
        {:names ["--retry-max-wait"]
         :key :retry-max-wait
         :value :number
         :scope :any
         :also [:mcp]
         :help "Max seconds to wait between retries (default: 300)"}
        {:names ["--base-url"]
         :key :base-url
         :value :string
         :arg "URL"
         :scope :any
         :also [:mcp]
         :help "Override base URL"}
        {:names ["--servers"]
         :key :servers
         :scope :op
         :help "List the schema's servers and their variables"}
        {:names ["--server-index"]
         :key :server-index
         :value :number
         :scope :any
         :also [:mcp]
         :help "Use the schema's Nth server (default: 1)"}
        {:family "--server."
         :shown "--server.NAME=VAL"
         :scope :any
         :also [:mcp]
         :help "Set a server URL variable (e.g. --server.zone=de-fra-1)"}
        {:family "--ssl."
         :shown "--ssl.KEY=VAL"
         :scope :any
         :also [:mcp :auth]
         :help "TLS option: cafile, capath, certificate, key, verify (e.g. --ssl.verify=none)"}
        {:names ["--output"]
         :key :output
         :value :string
         :arg "FORMAT"
         :choices [:json :yaml :raw :table :csv :tsv :status :headers]
         :scope :any
         :help "json (default), yaml, raw, table, csv, tsv, status or headers"}
        {:names ["--select"]
         :key :select
         :value :string
         :arg "PATH"
         :scope :op
         :also [:http :az]
         :help "Select nested value (e.g. .items[0].name, .items[].{id,name})"}
        {:names ["--no-color"]
         :key :no-color
         :scope :any
         :help "Disable colored output"}
        {:names ["--verbose" "-v"]
         :key :verbose
         :shown "-v, --verbose"
         :scope :any
         :also [:mcp]
         :help "Show status, headers and requests"}
        {:names ["--timing"]
         :key :timing
         :scope :any
         :help "Show how long each request took, phase by phase"}
        {:names ["--reload"]
         :key :reload
         :scope :op
         :also [:mcp]
         :help "Re-fetch and re-cache the schema"}
        {:names ["--ignore-status"]
         :key :ignore-status
         :scope :op
         :also [:http]
         :help "Treat HTTP error responses as output; exit 0"}
        {:names ["--no-validate"]
         :key :no-validate
         :scope :op
         :also [:az]
         :help "Send even if required params are missing or the body or inputs are invalid"}
        {:names ["--dry-run"]
         :key :dry-run
         :scope :op
         :also [:http]
         :explained [:az :profile]
         :help "Print the request instead of sending it"}
        {:names ["--curl"]
         :key :curl
         :scope :op
         :also [:http]
         :explained [:az]
         :help "Print an equivalent curl command instead of sending"}
        {:names ["--cache-ttl"]
         :key :cache-ttl
         :value :number
         :scope :op
         :also [:mcp]
         :help "Schema cache TTL in seconds (default: 3600)"}
        {:names ["--profile"]
         :key :profile
         :value :string
         :arg "NAME"
         :scope :az
         :also [:http]
         :help "Profile for auth, TLS and headers"}
        {:names ["--inputs"]
         :key :arazzo-inputs-blob
         :value :inputs
         :scope :az
         :help "All inputs as a JSON/YAML object (or @file)"}
        {:names ["--arazzo-output"]
         :key :arazzo-output
         :value :string
         :arg "MODE"
         :choices [:final :steps :progress :full]
         :scope :az
         :help "final (default), steps, progress, full"}
        {:names ["--link"]
         :key :link
         :scope :az
         :help "Print how to run a named document's workflows as their own command"}
        {:names ["--check"]
         :key :check
         :scope :az
         :help "Check the document against its sources without running it"}
        {:names ["--trust-sources"]
         :key :trust-sources
         :scope :az
         :help "Load Arazzo sources from anywhere, not only next to the document"}
        {:names ["--max-gotos"]
         :key :max-gotos
         :value :number
         :scope :az
         :help "Max gotos to one step before aborting (default: 50)"}
        {:names ["--arazzo"]
         :key :arazzo
         :value :string
         :arg "NAME"
         :scope :mcp
         :help "Also offer the workflows of an Arazzo context or file"}
        {:names ["--allow-writes"]
         :key :allow-writes
         :scope :mcp
         :help "Offer the operations that change things too, not only reads"}
        {:names ["--logout"]
         :key :logout
         :scope :auth
         :help "Clear the cached token instead of authenticating"}])

(local option-by-name (let [index {}]
                        (each [_ o (ipairs options)]
                          (each [_ n (ipairs (or o.names []))]
                            (tset index n o)))
                        index))

(fn field-arg [a]
  "For --PREFIX.KEY=VAL arguments with a known prefix (long or short form),
returns (kind key value); kind is a value of field-prefixes."
  (let [(prefix k v) (a:match "^%-%-(%a+)%.(.-)=(.*)$")
        kind (when prefix (. field-prefixes prefix))]
    (when kind
      (values kind k v))))

(local short-prefixes {:query "--q." :header "--h." :body "--b."})

(local ssl-options {:cafile true
                    :capath true
                    :certificate true
                    :key true
                    :verify true})

(fn add-field [r kind k v]
  (when (= k "")
    (error (.. (or (. short-prefixes kind) (.. "--" kind "."))
               " needs a field name, as in " (or (. short-prefixes kind) "--")
               "NAME=VALUE") 0))
  (match kind
    :query (let [prev (. r.query k)]
             ;; repeating a parameter sends it several times
             (tset r.query k (if (= nil prev) v
                                 (= (type prev) :table) (doto prev
                                                          (table.insert v))
                                 [prev v])))
    :header
    (let [existing (accumulate [found nil name (pairs r.headers) &until found]
                     (when (= (name:lower) (k:lower)) name))]
      ;; repeated header names, in any case, are joined like HTTP does; cookies
      ;; have their own separator
      (if existing
          (tset r.headers existing
                (.. (. r.headers existing) (if (= (k:lower) :cookie) "; " ", ")
                    v))
          (tset r.headers k v)))
    :body (table.insert r.body-fields [k v])
    :server (tset r.server-vars k v)
    :ssl (if (. ssl-options k)
             (tset r.ssl k v)
             (error (.. "unknown TLS option: " k
                        " (expected cafile, capath, certificate, key or verify)")
                    0))))

(fn option-value [name opt raw]
  (when (and opt.choices (not (accumulate [ok false _ c (ipairs opt.choices)
                                           &until ok]
                                (= c raw))))
    (error (.. name " must be one of " (table.concat opt.choices ", ")
               ", got '" raw "'") 0))
  (match opt.value
    :number
    (let [n (or (tonumber raw) (error (.. name " expects a number, got '" raw
                                          "'")
                                      0))]
      (when (and opt.positive (<= n 0))
        (error (.. name " must be greater than 0") 0))
      n)
    :body (read-body raw)
    :inputs (decode-structured (read-body raw))
    _ raw))

(fn accepted-elsewhere [opt]
  "Commands besides opt's :scope that the parser lets it through for."
  (let [commands (icollect [_ c (ipairs (or opt.also []))]
                   c)]
    (each [_ c (ipairs (or opt.explained []))]
      (table.insert commands c))
    commands))

(local command-scopes {:op :op
                       :http :http
                       :mcp :mcp
                       :az :az
                       :arazzo :az
                       :auth :auth
                       :profile :profile
                       :completion :completion})

;; the option entry of each --PREFIX.NAME=VALUE family, by field kind: its
;; :scope and :also say which commands take it
(local family-options (collect [_ o (ipairs options)]
                        (when o.family
                          (values (. field-prefixes
                                     (o.family:match "^%-%-(.-)%.$"))
                                  o))))

(fn check-scopes [cmd used]
  "Raise for an option that doesn't apply to command cmd; used is a list of
[name scope also]."
  (let [scope (. command-scopes (or cmd ""))]
    (when scope
      (each [_ [name opt-scope also] (ipairs used)]
        ;; :any is any API command: op, az and http
        (when (not (or (= opt-scope scope)
                       (and (= opt-scope :any)
                            (or (= scope :op) (= scope :az) (= scope :http)))
                       (accumulate [ok false _ s (ipairs (or also [])) &until ok]
                         (= s scope))))
          (error (.. name " doesn't apply to " cmd " (it is for "
                     (if (= opt-scope :any) "op, az and http" opt-scope) ")")
                 0))))))

(fn parse-args [args]
  (let [r {:path-params []
           ;; indexes of the path-params given after --: values, whatever
           ;; their shape
           :literal {}
           :query {}
           :headers {}
           :ssl {}
           :server-vars {}
           :body-fields []} ;; true when a went to path-params
        positional (fn [a]
                     (if (not r.cmd) (tset r :cmd a)
                         (not r.schema) (tset r :schema a)
                         (not r.operation) (tset r :operation a)
                         (do
                           (table.insert r.path-params a)
                           true)))
        used [] ;; how workflow inputs were once given: say how they are now
        removed-input (fn [a next-arg]
                        (let [example (or (a:match "^%-%-i%.(.+=.*)$")
                                          (a:match "^%-%-input%.(.+=.*)$")
                                          (a:match "^%-i(.+=.*)$") next-arg
                                          "name=value")]
                          (error (.. a
                                     " is gone: workflow inputs are name=value arguments, like "
                                     example)
                                 0)))]
    (var i 1)
    (var options-done false)

    (fn after-options [a]
      (when (positional a)
        (tset r.literal (length r.path-params) true)))

    (while (<= i (length args))
      (let [a (. args i)]
        (if options-done (after-options a) (= a "--") (set options-done true)
            (not (a:match "^%-")) (positional a) (field-arg a)
            (let [(kind k v) (field-arg a)]
              (table.insert used
                            [(a:match "^(%-%-?[%w-]+%.?)")
                             (?. family-options kind :scope)
                             (?. family-options kind :also)])
              (add-field r kind k v)) ;; -iKEY=VAL, glued
            (or (= a "-i") (a:match "^%-i.+=") (a:match "^%-%-i%.")
                (a:match "^%-%-input%."))
            (removed-input a (. args (+ i 1)))
            (let [(name inline) (if (a:find "=" 1 true)
                                    (a:match "^([^=]+)=(.*)$")
                                    a)
                  opt (or (. option-by-name name)
                          (error (.. "unknown option: " a) 0))]
              (table.insert used [name opt.scope (accepted-elsewhere opt)])
              (if (not opt.value)
                  (if inline
                      (error (.. name " takes no value") 0)
                      (tset r opt.key true))
                  (let [raw (or inline
                                (do
                                  (set i (+ i 1))
                                  (or (. args i)
                                      (error (.. name " requires a value") 0))))]
                    (tset r opt.key (option-value name opt raw)))))))
      (set i (+ i 1)))
    (check-scopes r.cmd used)
    r))

{: field-prefixes : field-arg : parse-args : options : option-by-name}
