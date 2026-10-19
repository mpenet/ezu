;; ABOUTME: Profile authentication: OAuth 2.0 flows with a token cache, and
;; ABOUTME: per-request signing by an external tool or a plugin's function.
(local json (require :ezu.json))
(local http (require :ezu.http))
(local util (require :ezu.util))
(local socket (require :socket))
(local digest (require :ezu.digest))
(local secrets (require :ezu.secrets))

;; ---- helpers ----

(fn cache-dir []
  (.. (util.cache-dir) "/tokens"))

(fn token-path [profile-name]
  (.. (cache-dir) "/" (util.url-encode profile-name) ".json"))

(local shell-quote util.shell-quote)

(fn param [params key]
  "params[key], read from its source (environment, file, command) when it
names one, or nil."
  (let [v (?. params key)]
    (when (not= nil v)
      (secrets.resolve v (.. "params." key)))))

(fn required-param [auth-config key]
  (let [v (?. auth-config :params key)]
    (assert (and v (not= v ""))
            (string.format "%s auth requires params.%s" auth-config.name key))
    (secrets.resolve v (.. "params." key))))

;; the parameters each authentication method can't do without
(local required-params
       {:bearer [:token]
        :basic [:username :password]
        :api-key [:name :value]
        :external-tool [:commandline]
        :oauth-client-credentials [:token_url :client_id]
        :oauth-authorization-code [:authorize_url :token_url :client_id]
        :oauth-device-authorization [:device_authorization_url
                                     :token_url
                                     :client_id]})

(fn signs? [auth-config]
  "Whether auth-config carries a plugin's function signing requests: never a
value from a configuration, which JSON can't hold."
  (= (type auth-config.sign) :function))

(fn built-in? [name]
  "Whether ezu itself provides authentication method name."
  (not= nil (. required-params name)))

(fn check-params [auth-config]
  "Raise naming the first parameter auth-config's method needs and lacks;
checked when authenticating, so a profile can be listed or shown anyway. An
env: value is only read where it is used (a cached token needs none)."
  (each [_ k (ipairs (or (. required-params auth-config.name) []))]
    (let [v (?. auth-config :params k)]
      (assert (and v (not= v ""))
              (string.format "%s auth requires params.%s" auth-config.name k)))))

(fn random-string [n]
  "n characters from [A-Za-z0-9] read from /dev/urandom, without modulo bias."
  (let [chars "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        nchars (length chars)
        limit (- 256 (% 256 nchars))
        f (assert (io.open "/dev/urandom" :rb)
                  "cannot read /dev/urandom for OAuth state")
        out []]
    (while (< (length out) n)
      (let [byte (string.byte (f:read 1))]
        (when (< byte limit)
          (let [i (+ 1 (% byte nchars))]
            (table.insert out (chars:sub i i))))))
    (f:close)
    (table.concat out)))

;; ---- token cache ----

(fn load-token [profile-name]
  (let [f (io.open (token-path profile-name) :r)]
    (when f
      (let [(ok data) (pcall json.decode (f:read :*a))]
        (f:close)
        (when (and ok data) data)))))

(fn save-token [profile-name data]
  (let [dir (cache-dir)
        path (token-path profile-name)]
    (os.execute (.. "mkdir -p " (shell-quote dir) " && chmod 700 "
                    (shell-quote dir)))
    (util.write-private path (json.encode data))))

(fn clear-token [profile-name]
  (os.remove (token-path profile-name)))

(fn token-valid? [data]
  (and data data.access_token
       (or (not data.expires_at) (> data.expires_at (+ (os.time) 30)))))

;; ---- HTTP form post ----

(fn post-form [url params net]
  "POST params as a form; net: {:ssl tls-options :timeout seconds}."
  (let [body (util.form-encode params)]
    (http.request {:method :POST
                   :url url
                   :headers {:content-type "application/x-www-form-urlencoded"
                             :accept "application/json"}
                   :raw-body body
                   :ssl (or (?. net :ssl) {})
                   :timeout (?. net :timeout)})))

(fn json-body [resp]
  "Response body as a table, null fields left out (a null token or expiry
means none): decoded from the raw text when there is one."
  (let [text (if (= (type resp.raw) :string) resp.raw
                 (= (type resp.body) :string) resp.body)]
    (if text
        (let [(ok decoded) (pcall json.decode text)]
          (when (and ok (= (type decoded) :table))
            decoded))
        (when (= (type resp.body) :table)
          resp.body))))

(fn issuer [params]
  "Who a token comes from: its token endpoint and client. A cached token is
used only with the auth settings that obtained it."
  (.. (tostring params.token_url) " " (tostring params.client_id)))

(fn store-token [resp profile-name params ?previous]
  (assert (util.success? resp.status)
          (let [body (json-body resp)
                detail (when body
                         (tostring (or body.error_description body.error "")))]
            (.. "token request failed: HTTP " resp.status
                (if (and detail (> (length detail) 0)) (.. " — " detail) ""))))
  (let [body (assert (json-body resp)
                     (.. "token response is not JSON: " (tostring resp.body)))
        _ (assert (and (= (type body.access_token) :string)
                       (not= body.access_token ""))
                  "token response has no access_token")
        data {:access_token body.access_token
              :token_type (or body.token_type "Bearer")
              :issuer (issuer params)}]
    (when body.expires_in
      (tset data :expires_at (+ (os.time) body.expires_in)))
    (match (or body.refresh_token (?. ?previous :refresh_token))
      refresh (tset data :refresh_token refresh))
    (save-token profile-name data)
    data))

;; ---- refresh ----

(fn client-form [params fields]
  "fields with the client's id and, when it has one, its secret."
  (doto fields
    (tset :client_id (param params :client_id))
    (tset :client_secret (param params :client_secret))))

(fn try-refresh [profile-name params net cached]
  (let [form (client-form params
                          {:grant_type "refresh_token"
                           :refresh_token cached.refresh_token})]
    (let [(ok resp) (pcall post-form (param params :token_url) form net)]
      (when (and ok (util.success? resp.status))
        (store-token resp profile-name params cached)))))

;; ---- client credentials ----

(fn client-credentials [profile-name params net]
  (let [form {:grant_type "client_credentials"
              :client_id (param params :client_id)
              :client_secret (or (param params :client_secret) "")}]
    (tset form :scope (param params :scope))
    (tset form :audience (param params :audience))
    (store-token (post-form (param params :token_url) form net) profile-name
                 params)))

;; ---- device authorization ----

(fn request-device-code [params net]
  "Start the device flow; returns the device authorization response body."
  (let [form (client-form params {})]
    (tset form :scope (param params :scope))
    (let [resp (post-form (or (param params :device_authorization_url)
                              (error "oauth-device-authorization requires device_authorization_url"))
                          form net)]
      (assert (util.success? resp.status)
              (.. "device authorization request failed: HTTP " resp.status))
      (let [body (assert (json-body resp)
                         "device authorization response is not JSON")]
        (assert body.device_code
                "device authorization response missing device_code")
        (assert body.user_code
                "device authorization response missing user_code")
        body))))

(fn poll-device-token [profile-name params net device]
  "Poll the token endpoint until the user approves, honouring slow_down;
returns the stored token, raising on expiry, denial or timeout."
  (var deadline (+ (os.time) (or device.expires_in 300)))
  (var interval (or device.interval 5))
  (var token nil)
  (while (and (not token) (< (os.time) deadline))
    (socket.sleep interval)
    (let [(ok resp) (pcall post-form (param params :token_url)
                           (client-form params
                                        {:grant_type "urn:ietf:params:oauth:grant-type:device_code"
                                         :device_code device.device_code})
                           net)
          body (when ok (json-body resp))]
      ;; some providers answer pending with 200 and an error field
      (if (and body (util.success? resp.status) (= nil body.error))
          (set token (store-token resp profile-name params))
          ;; keep polling while the user hasn't answered (or the network
          ;; failed); any other error is final
          (match (?. body :error)
            "slow_down"
            (set interval (+ interval 5))
            "authorization_pending"
            nil
            "expired_token"
            (error "device code expired")
            "access_denied"
            (error "device authorization denied by user")
            other
            (error (util.printable (.. "device authorization failed: "
                                       (tostring other)
                                       (if body.error_description
                                           (.. " — "
                                               (tostring body.error_description))
                                           ""))) 0)
            ;; a server error may pass
            _
            (when (and ok (< (or resp.status 0) 500))
              (error (.. "device authorization failed: HTTP "
                         (tostring resp.status)) 0))))))
  (or token (error "device authorization timed out")))

(fn device-authorization [profile-name params net]
  (let [device (request-device-code params net)]
    (io.stderr:write (util.printable (.. "Open this URL to authenticate:\n  "
                                         (tostring (or device.verification_uri_complete
                                                       device.verification_uri))
                                         "\nUser code: "
                                         (tostring device.user_code)
                                         "\nWaiting for authorization...\n")))
    (poll-device-token profile-name params net device)))

;; ---- authorization code (browser) ----

(fn open-browser [url]
  (let [h (io.popen "uname -s")
        sys (if h (let [s (h:read :*l)] (h:close) s) "Linux")
        quoted (shell-quote url)]
    ;; the browser gets neither ezu's stdin nor its stdout, which ezu mcp
    ;; uses for the protocol
    (if (= sys "Darwin")
        (os.execute (.. "open " quoted " < /dev/null > /dev/null"))
        (os.execute (.. "xdg-open " quoted " < /dev/null > /dev/null 2>&1 &")))))

(fn start-local-server [?port]
  (let [srv (socket.tcp)
        (ok-b err-b) (srv:bind "127.0.0.1" (or ?port 0))]
    (assert ok-b (.. "OAuth callback bind failed: " (tostring err-b)))
    (let [(ok-l err-l) (srv:listen 8)]
      (assert ok-l (.. "OAuth callback listen failed: " (tostring err-l)))
      (let [(_ port) (srv:getsockname)]
        (values srv port)))))

(fn parse-query [qs]
  (collect [k v (qs:gmatch "([^&=]+)=?([^&]*)")]
    (util.url-decode k)
    (util.url-decode v)))

(fn reply [client status body]
  (client:send (.. "HTTP/1.1 " status
                   "\r\nContent-Type: text/html; charset=utf-8\r\n"
                   "Connection: close\r\n\r\n<html><body>" body "</body></html>"))
  (client:close))

(fn read-request-target [client]
  "Request target of an HTTP request, after draining its headers."
  (client:settimeout 10)
  (let [first (client:receive "*l")]
    (var line first)
    (while (and line (> (length line) 0))
      (set line (client:receive "*l")))
    (when first (first:match "^GET (%S+) "))))

(fn wait-for-callback [srv expected-state callback-path]
  "Accept connections until the OAuth redirect to callback-path arrives;
other requests (favicon, probes) get a 404. Returns the authorization code."
  (let [deadline (+ (socket.gettime) 120)]
    (var result nil)
    (while (= result nil)
      (srv:settimeout (math.max 0 (- deadline (socket.gettime))))
      (let [(client err) (srv:accept)]
        (when (not client)
          (srv:close)
          (error (.. "OAuth callback timed out: " (tostring err))))
        (let [target (read-request-target client)
              (path qs) (when target (target:match "^([^?]*)%??(.*)$"))]
          (if (not= path callback-path)
              (reply client "404 Not Found" "Not found.")
              (let [params (parse-query qs)]
                ;; only a callback carrying our state comes from the provider
                (set result
                     (if (not= params.state expected-state)
                         {:failure "OAuth state mismatch — possible CSRF"}
                         params.error
                         {:failure (util.printable (.. "authorization failed: "
                                                       params.error
                                                       (if params.error_description
                                                           (.. " — "
                                                               params.error_description)
                                                           "")))}
                         (not params.code)
                         {:failure "no authorization code in callback"}
                         {:code params.code}))
                (if result.code
                    (reply client "200 OK"
                           "<h1>Authentication successful.</h1><p>You can close this tab.</p>")
                    (reply client "400 Bad Request"
                           "<h1>Authentication failed.</h1>")))))))
    (srv:close)
    (when result.failure (error result.failure))
    result.code))

(fn authorization-code [profile-name params net ?opts]
  (let [(srv port) (start-local-server params.redirect_port)
        redirect-host (or params.redirect_host "127.0.0.1")
        redirect-path (or params.redirect_path "/callback")
        redirect-uri (.. "http://" redirect-host ":" port redirect-path)
        state (random-string 32)
        code-verifier (random-string 64)
        auth-params {:response_type "code"
                     :client_id (param params :client_id)
                     :redirect_uri redirect-uri
                     :state state
                     :scope (or (param params :scope) "")
                     :code_challenge (digest.pkce-challenge code-verifier)
                     :code_challenge_method "S256"}]
    (let [auth-url (util.append-query (param params :authorize_url) auth-params)]
      (io.stderr:write (.. "Opening browser for authentication...\n"))
      (io.stderr:write (.. "If browser does not open, visit:\n" auth-url "\n"))
      ((or (?. ?opts :open-browser) open-browser) auth-url)
      (let [code (wait-for-callback srv state redirect-path)
            form (client-form params
                              {:grant_type "authorization_code"
                               : code
                               :redirect_uri redirect-uri
                               :code_verifier code-verifier})]
        (store-token (post-form (param params :token_url) form net)
                     profile-name params)))))

;; ---- external tool ----

(fn run-external [params stdin-json]
  (assert (param params :commandline)
          "external-tool auth requires params.commandline")
  (var tmp-path nil)
  (let [cmd (if stdin-json
                (let [tmp (os.tmpname)
                      f (io.open tmp :w)]
                  (assert f "failed to write external tool input")
                  (f:write stdin-json)
                  (f:close)
                  (set tmp-path tmp)
                  (.. "/bin/sh -c "
                      (shell-quote (.. "( " (param params :commandline)
                                       "\n) < " (shell-quote tmp)))))
                ;; never ezu's own stdin: under ezu mcp it carries the
                ;; protocol
                (.. "/bin/sh -c "
                    (shell-quote (.. "( " (param params :commandline)
                                     ;; on its own line: a # comment at the
                                     ;; end of the commandline can't hide it
                                     "\n) < /dev/null"))))
        h (io.popen cmd)]
    (assert h "failed to start external auth command")
    (let [out (h:read "*a")
          (ok _ code) (h:close)]
      (when tmp-path (os.remove tmp-path))
      (assert ok (.. "external auth command failed (exit " (tostring code) ")"))
      out)))

(fn external-bearer [params]
  (let [out (: (run-external params nil) :match "^%s*(.-)%s*$")]
    (assert (and out (> (length out) 0))
            "external auth command produced no output")
    {:authorization (.. "Bearer " out)}))

(fn external-signing-headers [params req]
  ;; Restish configs hold strings: "false" keeps the body
  (let [omit? (or (= params.omitbody true)
                  (= (: (tostring params.omitbody) :lower) "true"))
        body (when (not omit?)
               (or req.raw-body (when (= (type req.body) :string) req.body)
                   (when req.body
                     (let [(ok s) (pcall json.encode req.body)]
                       (when ok s))) ""))
        payload (json.encode {:method (or req.method "GET")
                              :uri req.url
                              :headers (or req.headers {})
                              :body (or body "")})
        raw (run-external params payload)
        (ok result) (pcall json.decode raw)]
    ;; anything but a JSON object means the request wasn't signed: it must
    ;; not go out as if it were
    (assert (and ok (= (type result) :table) (not (json.array? result))
                 (or (= nil result.headers) (= (type result.headers) :table)))
            "external auth command output is not a JSON object with headers")
    result.headers))

;; ---- public API ----

(fn authenticate [profile-name auth-config net ?opts]
  "Run the configured OAuth flow and cache the token.
?opts: {:open-browser (fn [url])} to replace the system browser launcher."
  (check-params auth-config)
  (let [params auth-config.params]
    (match auth-config.name
      "oauth-authorization-code" (authorization-code profile-name params net
                                                     ?opts)
      "oauth-client-credentials" (client-credentials profile-name params net)
      "oauth-device-authorization" (device-authorization profile-name params
                                                         net)
      _ (error (.. "unsupported auth type: " auth-config.name)))))

(fn ensure-token [profile-name auth-config net]
  ;; a token from other auth settings (another provider or client) is
  ;; neither used nor refreshed
  (let [stored (load-token profile-name)
        cached (when (and stored
                          (= stored.issuer (issuer (or auth-config.params {}))))
                 stored)]
    (if (token-valid? cached)
        cached.access_token
        (let [data (if (and cached cached.refresh_token)
                       (do
                         (io.stderr:write "Refreshing token...\n")
                         (or (try-refresh profile-name auth-config.params net
                                          cached)
                             (do
                               (io.stderr:write "Token refresh failed, re-authenticating...\n")
                               (authenticate profile-name auth-config net))))
                       (authenticate profile-name auth-config net))]
          data.access_token))))

(fn api-key-location [auth-config]
  "Where an api-key goes: header (the default), query or cookie."
  (let [in (or (?. auth-config :params :in) :header)]
    (assert (or (= in :header) (= in :query) (= in :cookie))
            (.. "api-key params.in must be header, query or cookie, not '"
                (tostring in) "'"))
    in))

(fn api-key-in-query? [auth-config]
  (and (= auth-config.name "api-key") (= (?. auth-config :params :in) "query")))

(fn get-headers [profile-name auth-config net]
  "Returns static headers for any auth type.
  bearer / basic / api-key (header): headers built from params.
  api-key in the query string: returns {} — the parameter is added via wrap-http-fn.
  For external-tool with output=bearer-token: runs command once, returns Authorization header.
  For external-tool signing mode: returns {} — per-request headers come via wrap-http-fn.
  OAuth types: returns {:authorization 'Bearer <token>'}.
  A plugin's signing function (:sign): returns {} — it signs each request."
  (check-params auth-config)
  (match (if (signs? auth-config) :plugin auth-config.name)
    :plugin {}
    "bearer" {:authorization (.. "Bearer " (required-param auth-config :token))}
    "basic" {:authorization (.. "Basic "
                                (digest.base64 (.. (required-param auth-config
                                                                   :username)
                                                   ":"
                                                   (required-param auth-config
                                                                   :password))))}
    "api-key" (match (api-key-location auth-config)
                :query {}
                :cookie {:cookie (.. (required-param auth-config :name) "="
                                     (required-param auth-config :value))}
                _ {(: (required-param auth-config :name) :lower) (required-param auth-config
                                                                                 :value)})
    "external-tool" (if (= (?. auth-config :params :output) "bearer-token")
                        (external-bearer auth-config.params)
                        {})
    _ {:authorization (.. "Bearer " (ensure-token profile-name auth-config net))}))

(fn header-names [auth-config]
  "Lowercased names of the headers get-headers will supply, without running
any auth flow; signing tools and plugins, and query api-keys, supply none up
front."
  (match (if (signs? auth-config) :plugin auth-config.name)
    :plugin []
    "api-key" (match (?. auth-config :params :in)
                :query []
                :cookie [:cookie]
                _ [(: (or (?. auth-config :params :name) "") :lower)])
    "external-tool" (if (= (?. auth-config :params :output) "bearer-token")
                        ["authorization"]
                        [])
    _ ["authorization"]))

(fn as-permanent [f ...]
  "f's result; an error it raises (an authentication failure, a request that
can't be built) becomes permanent, which retries leave alone (retry.fnl): it
doesn't go away by trying again."
  (let [(ok a b) (pcall f ...)]
    (if ok
        (values a b)
        (error (util.permanent-error (tostring a))))))

(fn wrap-api-key-query [auth-config base-fn]
  (fn [req]
    ;; read when a request is sent (env: values may be unset until then)
    (let [(name value) (as-permanent #(values (required-param auth-config :name)
                                              (required-param auth-config
                                                              :value)))]
      ;; next-page URLs from pagination may already carry the key
      (let [in-url? (util.query-has? (or req.url "") name)
            out (collect [k v (pairs req)] k v)]
        (when (not in-url?)
          (set out.query (doto (collect [k v (pairs (or req.query {}))]
                                 k
                                 v)
                           (tset name value))))
        ;; logs and dry runs must mask it whatever its name
        (set out.sensitive-query
             (doto (icollect [_ n (ipairs (or req.sensitive-query []))]
                     n)
               (table.insert name)))
        (base-fn out)))))

(fn wrap-signer [sign base-fn]
  "base-fn sending each request with the headers (sign request) returns, a
request whose URL has its query string and whose body is encoded, so the
signature covers what goes on the wire."
  (fn [caller-req]
    ;; signing rewrites url, body and headers: work on a copy
    (local req (collect [k v (pairs caller-req)] k v))
    (tset req :headers (collect [k v (pairs (or req.headers {}))]
                         k
                         v))
    (as-permanent #(do
                     ;; sign the URL that goes on the wire, query string
                     ;; included
                     (when req.query
                       (tset req :url
                             (util.append-query req.url req.query
                                                req.query-styles))
                       (tset req :query nil))
                     ;; pre-encode body so signing and wire use identical
                     ;; bytes
                     (when (and req.body (not req.raw-body))
                       (let [(_ payload headers) (http.encode-request req)]
                         (tset req :raw-body payload)
                         (tset req :headers headers)
                         (tset req :body nil)))))
    (let [extra (as-permanent sign req)]
      (when extra
        ;; what the signer adds is a credential, whatever its name
        (set req.sensitive-headers (icollect [_ n (ipairs (or req.sensitive-headers
                                                              []))]
                                     n))
        (each [k vs (pairs extra)]
          ;; header names are lowercase in ezu: no duplicate by case
          (tset req.headers (k:lower) (if (= (type vs) :table) (. vs 1) vs))
          (table.insert req.sensitive-headers (k:lower))))
      (base-fn req))))

;; what plugins get to sign requests with
(local plugin-helpers
       {:sha256 digest.sha256
        :hmac_sha256 digest.hmac-sha256
        :base64 digest.base64
        :unbase64 digest.unbase64
        :hex digest.hex
        :json {:encode json.encode :decode json.decode}
        :url {:parse (fn [url]
                       ;; LuaSocket splits ;params off the path: signatures
                       ;; cover the path as it is sent
                       (let [parsed ((. (require :socket.url) :parse) url)]
                         (when parsed.params
                           (set parsed.path
                                (.. (or parsed.path "") ";" parsed.params))
                           (set parsed.params nil))
                         parsed))
              ;; [[name value] ...] in order, decoded
              :query (fn [query]
                       (icollect [pair (string.gmatch (or query "") "[^&]+")]
                         (let [(name value) (pair:match "^([^=]*)=?(.*)$")]
                           [(util.url-decode name) (util.url-decode value)])))}})

(fn plugin-headers [auth-config req]
  "The headers auth-config's plugin function adds to req: it gets the request
as sent ({:method :url :headers :body}), the auth parameters (read from
their sources) and the helpers, and returns {:headers {name value}}."
  (let [params (collect [k v (pairs (or auth-config.params {}))]
                 k
                 (secrets.resolve v (.. "params." k)))
        (ok result) (pcall auth-config.sign
                           {:method req.method
                            :url req.url
                            :headers (collect [k v (pairs req.headers)] k v)
                            :body req.raw-body}
                           params plugin-helpers)
        fail #(error (.. "auth plugin '" (tostring auth-config.name)
                         "' failed: " $) 0)]
    (when (not ok)
      (fail (tostring result)))
    (when (not (and (= (type result) :table)
                    (or (= nil result.headers) (= (type result.headers) :table))))
      (fail "it must return a table with the headers to add, like {:headers {...}}"))
    result.headers))

(fn wrap-signing [auth-config base-fn]
  "base-fn signing each request when auth-config signs requests: with a
plugin's function, or an external tool."
  (if (signs? auth-config)
      (wrap-signer #(plugin-headers auth-config $) base-fn)
      (and (= auth-config.name "external-tool")
           (not= (?. auth-config :params :output) "bearer-token"))
      (wrap-signer #(do
                      (check-params auth-config)
                      (external-signing-headers auth-config.params $))
                   base-fn)))

(fn wrap-http-fn [auth-config base-fn]
  "Returns a per-request wrapper (query api-key or signing), or nil if not needed."
  (if (api-key-in-query? auth-config)
      (wrap-api-key-query auth-config base-fn)
      (wrap-signing auth-config base-fn)))

{: get-headers
 : built-in?
 : signs?
 : header-names
 : wrap-http-fn
 : api-key-in-query?
 : required-param
 : authenticate
 : clear-token
 : save-token
 : load-token
 : token-path
 : start-local-server
 : wait-for-callback}
