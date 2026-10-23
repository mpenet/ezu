;; ABOUTME: Config and profile resolution for the CLI: profiles, TLS, retry and
;; ABOUTME: pagination settings, and the client options shared by op and az.
(local ezu (require :ezu))
(local auth (require :ezu.auth))
(local plugins (require :ezu.cli.plugins))
(local cache (require :ezu.cache))
(local retry (require :ezu.retry))
(local paginate (require :ezu.paginate))
(local util (require :ezu.util))
(local secrets (require :ezu.secrets))
(local http-mod (require :ezu.http))
(local {: option-by-name} (require :ezu.cli.args))
(local json (require :ezu.json))
(local {: wrap-log-request
        : wrap-log-timing
        : request-text
        : curl-command
        : printing-transport} (require :ezu.cli.output))

(fn config-path []
  (.. (util.config-dir) "/config.json"))

(fn load-config []
  (let [f (io.open (config-path) :r)]
    (if f
        (let [(ok cfg) (pcall json.decode (f:read :*a))]
          (f:close)
          (if ok cfg (error (.. "corrupt config: " (config-path)))))
        {})))

(fn merge-profiles [base child]
  "child over base; headers merge by name, case-insensitively, the child's
winning."
  (let [result (collect [k v (pairs base)] k v)]
    (each [k v (pairs child)]
      (if (and (= k :headers) (= (type v) :table)
               (= (type (. result k)) :table))
          (let [overridden (collect [hk (pairs v)] (hk:lower)
                             true)
                merged (collect [hk hv (pairs (. result k))]
                         (when (not (. overridden (hk:lower)))
                           (values hk hv)))]
            (each [hk hv (pairs v)] (tset merged hk hv))
            (tset result k merged))
          (tset result k v)))
    result))

(fn object? [v]
  (and (= (type v) :table) (not= v json.null) (not (json.array? v))))

(fn resolve-profile [name profiles ?seen]
  (let [seen (or ?seen {})
        p (. profiles name)]
    (when (not p) (error (.. "Profile not found: " name) 0))
    (when (. seen name) (error (.. "Circular extends: " name) 0))
    (tset seen name true)
    (when (not (object? p))
      (error (.. "profile " name " must be an object") 0))
    (if p.extends
        (let [base (resolve-profile p.extends profiles seen)
              child (collect [k v (pairs p)] k v)]
          (tset child :extends nil)
          (merge-profiles base child))
        p)))

;; profile settings that hold JSON objects
(local object-settings [:auth :headers :query :ssl :tls :server :retry :mcp])

(fn check-config [config]
  "config, raising when it or its sections have the wrong shape."
  (when (not (object? config))
    (error "config must be a JSON object" 0))
  (each [_ k (ipairs [:profiles :arazzo :retry])]
    (when (not (or (= nil (. config k)) (object? (. config k))))
      (error (.. "config: " k " must be an object") 0)))
  (when (not (or (= nil config.plugins)
                 (and (= (type config.plugins) :table)
                      (not (object? config.plugins))
                      (accumulate [ok true _ p (ipairs config.plugins)
                                   &until (not ok)]
                        (= (type p) :string)))))
    (error "config: plugins must be a list of file paths" 0))
  (when (not (or (= nil config.timing) (= :boolean (type config.timing))))
    (error "config: timing must be true or false" 0))
  (each [name profile (pairs (or config.profiles {}))]
    (when (object? profile)
      (each [_ k (ipairs [:timing :no-paginate :check-response])]
        (when (not (or (= nil (. profile k)) (= :boolean (type (. profile k)))))
          (error (.. "config: profile " name ": " k " must be true or false") 0)))
      ;; values that may come from a secret source
      (each [section entries (pairs {:headers profile.headers
                                     :query profile.query
                                     "auth.params" (?. profile :auth :params)})]
        (when (object? entries)
          (each [k v (pairs entries)]
            (match (when (not= :number (type v)) (secrets.problem v))
              problem (error (.. "config: profile " name ": " section "." k " "
                                 problem) 0)))))))
  (each [name context (pairs (or config.arazzo {}))]
    (when (not (and (object? context) (= (type context.file) :string)))
      (error (.. "config: arazzo " name
                 " must be an object with a file, like {\"file\": \"flow.yaml\"}")
             0))
    (when (not (or (= nil context.inputs) (object? context.inputs)))
      (error (.. "config: arazzo " name ": inputs must be an object") 0))
    (when (not (or (= nil (. context :trust-sources))
                   (= :boolean (type (. context :trust-sources)))))
      (error (.. "config: arazzo " name ": trust-sources must be true or false")
             0))
    (let [listed (?. context :mcp :workflows)]
      (when (not (or (= nil (. context :mcp))
                     (and (object? context.mcp)
                          (or (= nil listed)
                              (and (= (type listed) :table)
                                   (not (object? listed))
                                   (accumulate [ok true _ w (ipairs listed)
                                                &until (not ok)]
                                     (= (type w) :string)))))))
        (error (.. "config: arazzo " name
                   ": mcp.workflows must be a list of command words or workflow ids, * for any text")
               0)))
    (let [n (. context :max-gotos)]
      (when (not (or (= nil n) (and (= (math.type n) :integer) (> n 0))))
        (error (.. "config: arazzo " name
                   ": max-gotos must be a positive integer") 0)))
    (let [modes (. option-by-name "--arazzo-output" :choices)
          mode (. context :arazzo-output)]
      (when (not (or (= nil mode)
                     (accumulate [found false _ m (ipairs modes) &until found]
                       (= m mode))))
        (error (.. "config: arazzo " name ": arazzo-output must be one of "
                   (table.concat modes ", ")) 0))))
  config)

(fn check-profile [name profile]
  "profile, raising when a setting has the wrong shape: a mistyped setting
would otherwise be ignored, auth included."
  (when (not (object? profile))
    (error (.. "profile " name " must be an object") 0))
  (each [_ k (ipairs object-settings)]
    (when (not (or (= nil (. profile k)) (object? (. profile k))))
      (error (.. "profile " name ": " k " must be an object") 0)))
  (when (not (or (= nil profile.schema) (= (type profile.schema) :string)))
    (error (.. "profile " name ": schema must be a string (a URL or a path)") 0))
  (when (and profile.auth (not= (type profile.auth.name) :string))
    (error (.. "profile " name
               ": auth needs a name (bearer, basic, api-key, external-tool, oauth-...)")
           0))
  (when profile.auth
    (when (not (or (= nil profile.auth.params) (object? profile.auth.params)))
      (error (.. "profile " name ": auth params must be an object") 0)))
  (let [ops (?. profile :mcp :operations)]
    (when (not (or (= nil ops)
                   (and (= (type ops) :table) (not (object? ops))
                        (accumulate [ok true _ op (ipairs ops) &until (not ok)]
                          (= (type op) :string)))))
      (error (.. "profile " name
                 ": mcp.operations must be a list of operation names")
             0)))
  profile)

(fn find-profile [config name]
  "Profile name of config with extends resolved, or nil when there is none."
  (let [profiles (or (?. config :profiles) {})]
    (when (and name (. profiles name))
      (check-profile name (resolve-profile name profiles {})))))

(fn tls->ssl [tls]
  (when tls
    (let [ssl {}]
      (when tls.cert (tset ssl :certificate tls.cert))
      (when tls.key (tset ssl :key tls.key))
      (when tls.insecure (tset ssl :verify "none"))
      (when tls.ca_cert (tset ssl :cafile tls.ca_cert))
      (when (next ssl) ssl))))

(fn merge-ssl [profile cli-ssl]
  (let [ssl (collect [k v (pairs (or (?. profile :ssl) {}))]
              k
              v)
        tls (tls->ssl (?. profile :tls))]
    (when tls
      (each [k v (pairs tls)] (tset ssl k v)))
    (when cli-ssl
      (each [k v (pairs cli-ssl)] (tset ssl k v)))
    ssl))

(fn retry-options [profile p config]
  "Retry settings: CLI flags, then profile, then config, then defaults."
  (let [pick #(let [v (. p $1)]
                (if (not= nil v) v
                    (not= nil (?. profile :retry $2)) (?. profile :retry $2)
                    (not= nil (?. config :retry $2)) (?. config :retry $2)
                    $3))]
    {:attempts (pick :retry :attempts 2)
     :unsafe (pick :retry-unsafe :unsafe false)
     :max-wait (pick :retry-max-wait :max-wait 300)}))

(fn paginate-options [profile p config]
  "Pagination settings, or nil when disabled."
  (when (not p.no-paginate)
    {:max-pages (or p.max-pages (?. profile :max-pages) (?. config :max-pages)
                    25)}))

(fn colors-wanted? [?env ?terminal?]
  "Whether output may be coloured: stdout is a terminal and NO_COLOR is unset
or empty (https://no-color.org)."
  (let [no-color (if ?env (. ?env :NO_COLOR) (os.getenv :NO_COLOR))]
    (and (or (= nil no-color) (= no-color ""))
         (if ?terminal?
             (?terminal?)
             (util.terminal? 1)))))

(fn display-options [profile p config ?colors]
  "Output settings: command line, then profile, then config, the first set
winning. Colour is also off when ?colors (default: colors-wanted?) says so."
  (let [first-set (fn [key]
                    ;; first one set wins, so false can override true
                    (let [sources [p profile config]]
                      (var found nil)
                      (for [i 1 3 &until (not= nil found)]
                        (set found (?. sources i key)))
                      found))]
    {:output (first-set :output)
     :no-color (or (first-set :no-color)
                   (not (if (= nil ?colors) (colors-wanted?) ?colors)))
     :verbose (first-set :verbose)}))

(fn configured-flags [p profile config ?named]
  "p with what the configuration says for the flags its command line left
out, the first set winning: timing (profile, then top level), no-paginate and
check-response (profile), max-gotos (?named, the workflow document)."
  (let [first-set (fn [key ...]
                    (let [sources [...]]
                      (var found nil)
                      (for [i 1 (select "#" ...) &until (not= nil found)]
                        (set found (?. sources i key)))
                      found))]
    (doto (collect [k v (pairs p)] k v)
      (tset :timing (first-set :timing p profile config))
      (tset :no-paginate (first-set :no-paginate p profile))
      (tset :check-response (first-set :check-response p profile))
      (tset :max-gotos (first-set :max-gotos p ?named)))))

(fn request-timeout [profile p config]
  "Seconds a request may take: --timeout, then profile, then config."
  (or p.timeout (?. profile :timeout) (?. config :timeout)))

(fn lazy-auth-headers [profile-name auth-cfg net]
  "Getter for the profile's auth headers, authenticating on first use only;
net: {:ssl :timeout} for the token endpoint."
  (var headers nil)
  (fn []
    (when (= nil headers)
      (let [(ok h) (pcall auth.get-headers profile-name auth-cfg net)]
        (assert ok (.. "authentication failed: " (tostring h)))
        (set headers (collect [k v (pairs h)] (k:lower) v))))
    headers))

(fn header-key [headers name]
  "The key of headers that holds header name (names ignore case), or nil."
  (accumulate [found nil k (pairs headers) &until found]
    (when (= (k:lower) (name:lower)) k)))

(fn has-cookie? [headers name]
  "Whether the request's Cookie header has a cookie called name."
  (let [present (util.header headers :cookie)]
    (and present (accumulate [found false part (present:gmatch "[^;]+")
                              &until found]
                   (= (part:match "^%s*([^=]+)=") name)))))

(fn add-cookie [headers cookie]
  "Add cookie (\"name=value\") to the request's Cookie header, unless one of
that name is already there."
  (let [key (header-key headers :cookie)]
    (if (not key) (tset headers :cookie cookie)
        (not (has-cookie? headers (cookie:match "^([^=]+)="))) (tset headers
                                                                     key
                                                                     (.. (. headers
                                                                            key)
                                                                         "; "
                                                                         cookie)))))

(fn add-auth-header [headers k v]
  "Add auth header k unless the request sets it; a cookie joins the others."
  (if (= (k:lower) :cookie) (add-cookie headers v)
      (= nil (util.header headers k)) (tset headers k v)))

(fn with-auth-headers [auth-headers names ?cookie-name base-fn]
  "Adds auth headers to each request; headers already set explicitly win, and
when they cover every auth header (names), auth doesn't run at all. A cookie
(?cookie-name) joins the request's other cookies, and only one of its name
covers it."
  (fn [req]
    (let [headers (collect [k v (pairs (or req.headers {}))]
                    k
                    v)
          covered (and (next names)
                       (accumulate [all true _ n (ipairs names) &until (not all)]
                         (if (= n :cookie)
                             (and ?cookie-name
                                  (has-cookie? headers ?cookie-name))
                             (not= nil (util.header headers n)))))]
      (when (not covered)
        (each [k v (pairs (auth-headers))]
          (add-auth-header headers k v)))
      (base-fn (doto (collect [k v (pairs req)] k v)
                 (tset :headers headers)
                 ;; redirects to another origin must drop them
                 (tset :sensitive-headers names))))))

(fn with-profile-query [query base-fn ?dry-run]
  "Adds the profile's query parameters to each request; explicit ones win.
A value read from a secret source is read on first use (never for
?dry-run, which shows <auth>) and counts as a credential."
  (fn [req]
    (let [merged {}
          sensitive (icollect [_ n (ipairs (or req.sensitive-query []))]
                      n)]
      (each [k v (pairs query)]
        (if (secrets.source? v)
            (do
              (tset merged k
                    (if ?dry-run "<auth>" (secrets.resolve v (.. "query." k))))
              (table.insert sensitive k))
            (tset merged k v)))
      (each [k v (pairs (or req.query {}))]
        (tset merged k v))
      (base-fn (doto (collect [k v (pairs req)] k v)
                 (tset :query merged)
                 (tset :sensitive-query sensitive))))))

(fn check-unused-server-vars [profile-name profile p]
  "Server variables only fill in the spec's servers: refuses those a base-url
leaves unused, --server.NAME with any base-url, and the profile's server
when the profile sets base-url itself."
  (let [base-url-by (if p.base-url "--base-url"
                        (?. profile :base-url) (.. "profile " profile-name
                                                   "'s base-url"))
        flag-var (next (or p.server-vars {}))
        profile-var (when (and (?. profile :base-url) (not p.base-url))
                      (next (or (?. profile :server) {})))
        unused (if flag-var (.. "--server." flag-var)
                   profile-var (.. "server." profile-var " of profile "
                                   profile-name))]
    (when (and base-url-by unused)
      (error (.. unused " has no effect: " base-url-by
                 " replaces the spec's servers") 0))))

(fn client-options [profile-name profile p config ?transport]
  "Client options shared by op and az: profile headers, ssl, timeout, servers,
and the http-fn: auth headers (added on first use), pagination, retries,
request signing, logging, and the transport (or dry-run printing)."
  (check-unused-server-vars profile-name profile p)
  (let [ssl (merge-ssl profile p.ssl)
        verbose (. (display-options profile p config) :verbose)
        auth-cfg (let [a (?. profile :auth)]
                   (when (and a a.name (not= a.name ""))
                     (plugins.resolve-auth config a)))
        ;; profile headers whose values a secret source gives count as
        ;; credentials, as auth headers do
        secret-headers (collect [k v (pairs (or (?. profile :headers) {}))]
                         (when (secrets.source? v) (values (k:lower) v)))
        auth-names (doto (if auth-cfg (auth.header-names auth-cfg) [])
                     (#(each [k (pairs secret-headers)]
                         (table.insert $ k))))
        dry-run (and p.dry-run (not p.curl))
        authenticated (when auth-cfg
                        (lazy-auth-headers profile-name auth-cfg
                                           {: ssl
                                            :timeout (request-timeout profile p
                                                                      config)}))
        auth-headers (when (next auth-names)
                       (if dry-run
                           ;; --dry-run redacts credentials anyway: don't
                           ;; authenticate, nor read secrets
                           #(collect [_ n (ipairs auth-names)] n "<auth>")
                           #(doto (if authenticated
                                      (collect [k v (pairs (authenticated))]
                                        k
                                        v)
                                      {})
                              (#(each [k v (pairs secret-headers)]
                                  (tset $ k
                                        (secrets.resolve v (.. "headers." k))))))))
        transport (if p.curl (printing-transport curl-command) p.dry-run
                      (printing-transport request-text)
                      (or ?transport http-mod.request))
        logged (if verbose (wrap-log-request transport)
                   p.timing (wrap-log-timing transport)
                   transport)
        ;; nor run a signing tool or plugin, or read a query key
        wrapper-cfg (if (and dry-run auth-cfg (auth.api-key-in-query? auth-cfg))
                        (doto (collect [k v (pairs auth-cfg)] k v)
                          (tset :params
                                (doto (collect [k v (pairs auth-cfg.params)] k
                                        v)
                                  (tset :value "<auth>"))))
                        auth-cfg)
        signed (or (when (and wrapper-cfg
                              (not (and dry-run
                                        (or (= wrapper-cfg.name "external-tool")
                                            (auth.signs? wrapper-cfg)))))
                     (auth.wrap-http-fn wrapper-cfg logged))
                   logged)
        retrying (retry.wrap signed (retry-options profile p config))
        pagination (paginate-options profile p config)
        paginated (if pagination (paginate.wrap retrying pagination) retrying)
        queried (if (?. profile :query)
                    (with-profile-query profile.query paginated dry-run)
                    paginated)]
    {:headers (collect [k v (pairs (or (?. profile :headers) {}))]
                (when (not (secrets.source? v)) (values (k:lower) v)))
     :auth-headers auth-headers
     ;; the authentication that isn't headers, for spec fetches
     :authorize (when (and auth-cfg (not p.dry-run))
                  #(or (auth.wrap-http-fn auth-cfg $) $))
     :auth-header-names auth-names
     ;; query parameters added to every request
     :implied-query (let [names (collect [k (pairs (or (?. profile :query) {}))]
                                  k
                                  true)
                          key (when (and auth-cfg
                                         (auth.api-key-in-query? auth-cfg))
                                (?. auth-cfg :params :name))]
                      (when key (tset names key true))
                      names)
     :ssl ssl
     :timeout (request-timeout profile p config)
     :base-url (or p.base-url (?. profile :base-url))
     :server-index (or p.server-index (?. profile :server-index))
     :server-vars (let [vars (collect [k v (pairs (or (?. profile :server) {}))]
                               k
                               v)]
                    (each [k v (pairs (or p.server-vars {}))]
                      (tset vars k v))
                    vars)
     ;; auth headers are added outside retries and pagination: computed once
     ;; per request, reused by every attempt and page, and an auth failure is
     ;; reported rather than retried as if it were a network error
     :http-fn (if auth-headers
                  (with-auth-headers auth-headers
                    auth-names
                    (when (= (?. auth-cfg :params :in) :cookie)
                      (?. auth-cfg :params :name))
                    queried)
                  queried)}))

(fn fetch-document [url opts]
  "The response to GET url through opts.transport. Credentials are only sent
after the server answers 401/403, so help and listings don't trigger
authentication; headers and credentials are not sent at all when url is on
another origin than the API's :base-url. :authorize wraps a transport with
the authentication that isn't headers (a query key, request signing).
opts: {:transport :headers :ssl :timeout :auth-headers :authorize :base-url}"
  (let [opts (if (and opts.base-url
                      (not= (util.origin url) (util.origin opts.base-url)))
                 {:transport opts.transport
                  :ssl opts.ssl
                  :timeout opts.timeout}
                 opts)
        send #($1 {:method "GET"
                   : url
                   :headers $2
                   :ssl opts.ssl
                   :timeout opts.timeout
                   :sensitive-headers $3})
        first (send opts.transport (or opts.headers {}))
        ;; asked to authenticate: 401/403, or sent to a sign-in page on
        ;; another origin (an auth proxy's redirect)
        resp (if (and (or opts.auth-headers opts.authorize)
                      (or (= first.status 401) (= first.status 403)
                          (and first.url
                               (not= (util.origin first.url) (util.origin url)))))
                 (let [headers (collect [k v (pairs (or opts.headers {}))]
                                 k
                                 v)
                       added []]
                   (each [k v (pairs (if opts.auth-headers
                                         (opts.auth-headers)
                                         {}))]
                     (add-auth-header headers k v)
                     (table.insert added k))
                   ;; a redirect to another origin must drop them
                   (send (if opts.authorize
                             (opts.authorize opts.transport)
                             opts.transport) headers
                         added))
                 first)]
    resp))

(fn fetch-schema [url opts]
  "Fetch and parse a schema URL (see fetch-document for opts)."
  (let [resp (fetch-document url opts)]
    (assert (util.success? resp.status)
            (string.format "HTTP %s fetching schema from %s" resp.status
                           (util.redact-url url)))
    (ezu.parse-schema (or resp.raw "") url)))

(fn load-schema-cached [url opts]
  "Schema at url from the cache when fresh, else fetched and cached.
opts: fetch-schema options plus {:ttl seconds :reload bool :cache bool}"
  (let [use-cache (not= opts.cache false)
        cached (when (and use-cache (not opts.reload))
                 (cache.get url (or opts.ttl 3600)))]
    (or cached (let [schema (fetch-schema url opts)]
                 (when use-cache (cache.put url schema))
                 schema))))

;; Link relations naming an API's description (RFC 8631, RFC 6892)
(local description-rels {:service-desc true
                         :service-doc true
                         :describedby true})

(fn spec? [doc]
  (and (= (type doc) :table) (not= nil (or doc.openapi doc.swagger))))

(fn under [base file]
  "base with file appended to its path, its query kept, its fragment left."
  (let [(path query) (base:match "^([^?#]*)(%??[^#]*)")]
    (.. (pick-values 1 (path:gsub "/+$" "")) "/" file query)))

(fn find-schema [base opts]
  "(location doc) of the OpenAPI description of the API at base, or (nil
reasons), what each place answered: a same-origin Link of the base URL
(service-desc, service-doc, describedby), openapi.json and openapi.yaml under
it, the base URL itself, then openapi.json and openapi.yaml at the origin's
root. Nothing is cached here."
  (let [reasons []
        (reached resp) (pcall fetch-document base opts)
        candidates (icollect [_ ref (ipairs (if reached
                                                (util.link-urls resp.headers
                                                                description-rels)
                                                []))]
                     (let [url (util.resolve-reference base ref)]
                       ;; a link elsewhere could hand ezu any API
                       (when (= (util.origin url) (util.origin base)) url)))
        root (base:match "^(%a[%w+.-]*://[^/?#]*)")
        path (or (base:match "^%a[%w+.-]*://[^/?#]*([^?#]*)") "")]
    (each [_ url (ipairs [(under base "openapi.json")
                          (under base "openapi.yaml")
                          base])]
      (table.insert candidates url))
    (when (and root (not= (path:gsub "/+$" "") ""))
      (table.insert candidates (.. root "/openapi.json"))
      (table.insert candidates (.. root "/openapi.yaml")))
    (var found nil)
    (each [_ url (ipairs candidates) &until found]
      (let [(fetched doc) (if (not= url base) (pcall fetch-schema url opts)
                              ;; the base URL was fetched already
                              (not reached) (values false resp)
                              (not (util.success? resp.status))
                              (values false
                                      (string.format "HTTP %s fetching %s"
                                                     resp.status
                                                     (util.redact-url base)))
                              (pcall ezu.parse-schema (or resp.raw "") base))]
        (if (and fetched (spec? doc)) (set found [url doc]) fetched
            (table.insert reasons
                          (.. (util.redact-url url)
                              " is not an OpenAPI document"))
            (table.insert reasons (tostring doc)))))
    (if found
        (values (. found 1) (. found 2))
        (values nil reasons))))

(fn discovery-key [base]
  (.. "discovery " base))

(fn discovered-schema [base ttl]
  "Where discovery found the spec of the API at base, when the cache still
knows, else nil."
  (?. (cache.get (discovery-key base) ttl) :location))

(fn discover-schema [base opts]
  "(location doc) of the OpenAPI description of the API at base (see
find-schema): doc when it was just fetched, nil when the location comes from
the cache; or (nil nil reasons). What is found is cached like specs."
  (let [use-cache (not= opts.cache false)
        known (when (and use-cache (not opts.reload))
                (discovered-schema base (or opts.ttl 3600)))]
    (if known
        (values known nil)
        (let [(location found) (find-schema base opts)]
          (if location
              (do
                (when use-cache
                  (cache.put (discovery-key base) {: location})
                  (cache.put location found))
                (values location found))
              (values nil nil found))))))

{: config-path
 : colors-wanted?
 : find-profile
 : load-config
 : merge-profiles
 : resolve-profile
 : tls->ssl
 : merge-ssl
 : retry-options
 : paginate-options
 : client-options
 : check-config
 : request-timeout
 : configured-flags
 : display-options
 : fetch-schema
 : load-schema-cached
 : discover-schema
 : discovered-schema}
