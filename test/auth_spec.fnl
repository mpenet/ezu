;; ABOUTME: Specs for OAuth flows, token storage, callback listener and external-tool auth.
;; ABOUTME: Run with `make test` (busted, Fennel loader).
(local json (require :lunajson))

;; ---- helpers ----

(fn json-body [t] (json.encode t))

(fn ok-resp [body]
  {:status 200 :headers {} :body body})

(fn err-resp [body ?status]
  {:status (or ?status 400) :headers {} :body body})

(local real-http (require :ezu.http))

(fn seq-mock [& resps]
  "Returns an ezu.http-compatible module whose request fn yields resps in order."
  (var idx 0)
  (var calls [])
  (values {:encode-body real-http.encode-body
           :encode-request real-http.encode-request
           :request (fn [req]
                      (table.insert calls req)
                      (set idx (+ idx 1))
                      (or (. resps idx) (ok-resp {})))} calls))

(fn mock-socket [?sleep-fn]
  {:sleep (or ?sleep-fn (fn [] nil)) :gettime (fn [] (os.time))})

(local real-socket (require :socket))

(fn reload-auth [http-mod ?sock-mod]
  (tset package.loaded :ezu.auth nil)
  (tset package.loaded :ezu.http http-mod)
  (tset package.loaded :socket (or ?sock-mod real-socket))
  (require :ezu.auth))

(fn tmp-profile []
  (.. "test-auth-" (tostring (math.random 100000 999999))))

(fn clean-token [profile-name]
  (os.remove ((. (require :ezu.auth) :token-path) profile-name)))

;; ---- client credentials ----

(describe "oauth-client-credentials"
          (fn []
            (it "sends correct grant_type, client_id and client_secret"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp (json-body {:access_token "tok"
                                                                    :expires_in 3600})))
                        auth (reload-auth http)
                        profile (tmp-profile)]
                    (auth.authenticate profile
                                       {:name "oauth-client-credentials"
                                        :params {:token_url "https://auth.example.com/token"
                                                 :client_id "my-client"
                                                 :client_secret "my-secret"}}
                                       {})
                    (clean-token profile)
                    (assert.are.equal 1 (length calls))
                    (let [req (. calls 1)
                          body req.raw-body]
                      (assert.is_truthy (body:find "grant_type=client_credentials"
                                                   1 true))
                      (assert.is_truthy (body:find "client_id=my-client" 1 true))
                      (assert.is_truthy (body:find "client_secret=my-secret" 1
                                                   true))))))
            (it "sends the token request with the timeout and TLS options"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp (json-body {:access_token "t"})))
                        auth (reload-auth http)
                        profile (tmp-profile)]
                    (auth.get-headers profile
                                      {:name "oauth-client-credentials"
                                       :params {:token_url "https://auth.example.com/token"
                                                :client_id "c"
                                                :client_secret "s"}}
                                      {:ssl {:verify "none"} :timeout 3})
                    (clean-token profile)
                    (assert.are.equal 3 (. calls 1 :timeout))
                    (assert.are.same {:verify "none"} (. calls 1 :ssl)))))
            (it "requires an access_token in the response"
                (fn []
                  (let [(http) (seq-mock (ok-resp (json-body {:token_type "bearer"})))
                        auth (reload-auth http)
                        profile (tmp-profile)
                        (ok err) (pcall auth.authenticate profile
                                        {:name "oauth-client-credentials"
                                         :params {:token_url "https://auth.example.com/token"
                                                  :client_id "c"
                                                  :client_secret "s"}}
                                        {})]
                    (clean-token profile)
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "token response has no access_token" 1
                                         true)))))
            (it "includes scope when provided"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp (json-body {:access_token "tok"
                                                                    :expires_in 3600})))
                        auth (reload-auth http)
                        profile (tmp-profile)]
                    (auth.authenticate profile
                                       {:name "oauth-client-credentials"
                                        :params {:token_url "https://auth.example.com/token"
                                                 :client_id "c"
                                                 :client_secret "s"
                                                 :scope "read write"}}
                                       {})
                    (clean-token profile)
                    (let [body (?. calls 1 :raw-body)]
                      (assert.is_truthy (body:find "scope=read" 1 true))))))
            (it "expands env: prefix in client_secret"
                (fn []
                  (os.execute "export _EZU_TEST_SECRET=env-secret 2>/dev/null; true")
                  ;; setenv workaround via a known-set var
                  (let [(http calls) (seq-mock (ok-resp (json-body {:access_token "tok"
                                                                    :expires_in 3600})))
                        auth (reload-auth http)
                        profile (tmp-profile)
                        _ (os.execute "export _EZU_TEST_SECRET=env-secret")]
                    ;; only test that env: expansion is attempted and errors clearly when var missing
                    (assert.has.error (fn []
                                        (auth.authenticate profile
                                                           {:name "oauth-client-credentials"
                                                            :params {:token_url "https://auth.example.com/token"
                                                                     :client_id "c"
                                                                     :client_secret "env:_EZU_DEFINITELY_NOT_SET_XYZ"}}
                                                           {})))
                    (clean-token profile))))
            (it "errors on non-2xx token response"
                (fn []
                  (let [(http) (seq-mock (err-resp (json-body {:error "invalid_client"})
                                                   401))
                        auth (reload-auth http)
                        profile (tmp-profile)]
                    (assert.has.error (fn []
                                        (auth.authenticate profile
                                                           {:name "oauth-client-credentials"
                                                            :params {:token_url "https://auth.example.com/token"
                                                                     :client_id "c"
                                                                     :client_secret "s"}}
                                                           {}))))))
            (it "reports the provider's error description"
                (fn []
                  (let [(http) (seq-mock (err-resp {:error "invalid_client"
                                                    :error_description "bad secret"}
                                                   401))
                        auth (reload-auth http)
                        (ok err) (pcall auth.authenticate (tmp-profile)
                                        {:name "oauth-client-credentials"
                                         :params {:token_url "https://auth.example.com/token"
                                                  :client_id "c"
                                                  :client_secret "s"}}
                                        {})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "token request failed: HTTP 401 — bad secret"
                                         1 true)))))
            (it "sends audience and reads env: secrets"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp (json-body {:access_token "tok"})))
                        auth (reload-auth http)
                        profile (tmp-profile)]
                    (auth.authenticate profile
                                       {:name "oauth-client-credentials"
                                        :params {:token_url "https://auth.example.com/token"
                                                 :client_id "c"
                                                 :client_secret "env:HOME"
                                                 :audience "api://x"}}
                                       {})
                    (clean-token profile)
                    (let [body (. calls 1 :raw-body)
                          util (require :ezu.util)]
                      (assert.is_truthy (body:find "audience=api%3A%2F%2Fx" 1
                                                   true))
                      (assert.is_truthy (body:find (.. "client_secret="
                                                       (util.url-encode (os.getenv :HOME)))
                                                   1 true))))))
            (it "ignores null fields of a token response"
                (fn []
                  (let [http-json (require :ezu.json)
                        body "{\"access_token\":\"tok\",\"refresh_token\":null,\"expires_in\":null}"
                        (http) (seq-mock {:status 200
                                          :headers {}
                                          :body (http-json.decode body true)
                                          :raw body})
                        auth (reload-auth http)
                        profile (tmp-profile)]
                    (auth.authenticate profile
                                       {:name "oauth-client-credentials"
                                        :params {:token_url "https://a/token"
                                                 :client_id "c"
                                                 :client_secret "s"}}
                                       {})
                    (let [saved (auth.load-token profile)]
                      (clean-token profile)
                      (assert.are.equal "tok" saved.access_token)
                      (assert.is_nil saved.refresh_token)
                      (assert.is_nil saved.expires_at)))))
            (it "reuses a stored token while it is valid"
                (fn []
                  (let [(http calls) (seq-mock)
                        auth (reload-auth http)
                        profile (tmp-profile)]
                    (auth.save-token profile
                                     {:access_token "cached"
                                      :expires_at (+ (os.time) 3600)
                                      :issuer "https://a/token c"})
                    (let [h (auth.get-headers profile
                                              {:name "oauth-client-credentials"
                                               :params {:token_url "https://a/token"
                                                        :client_id "c"}}
                                              {})]
                      (clean-token profile)
                      (assert.are.same {:authorization "Bearer cached"} h)
                      (assert.are.equal 0 (length calls))))))
            (it "uses a valid cached token without reading env: parameters"
                (fn []
                  (let [(http calls) (seq-mock)
                        auth (reload-auth http)
                        profile (tmp-profile)
                        cfg {:name "oauth-client-credentials"
                             :params {:token_url "https://id.example/token"
                                      :client_id "env:EZU_TEST_UNSET_CID"
                                      :client_secret "env:EZU_TEST_UNSET_CS"}}]
                    (auth.save-token profile
                                     {:access_token "tok"
                                      :expires_at (+ (os.time) 3600)
                                      :issuer "https://id.example/token env:EZU_TEST_UNSET_CID"})
                    (let [(ok h) (pcall auth.get-headers profile cfg {})]
                      (clean-token profile)
                      (assert.is_true ok h)
                      (assert.are.same {:authorization "Bearer tok"} h)
                      (assert.are.equal 0 (length calls))))))
            (it "reads env: in URL parameters too"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp (json-body {:access_token "t"})))
                        auth (reload-auth http)
                        profile (tmp-profile)]
                    (auth.get-headers profile
                                      {:name "oauth-client-credentials"
                                       :params {:token_url "env:HOME"
                                                :client_id "c"
                                                :client_secret "s"}}
                                      {})
                    (clean-token profile)
                    (assert.are.equal (os.getenv :HOME) (. calls 1 :url)))))
            (it "ignores a token another provider or client issued"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp (json-body {:access_token "fresh"})))
                        auth (reload-auth http)
                        profile (tmp-profile)]
                    (auth.save-token profile
                                     {:access_token "cached"
                                      :expires_at (+ (os.time) 3600)
                                      :refresh_token "r-old"
                                      :issuer "https://other/token c"})
                    (let [h (auth.get-headers profile
                                              {:name "oauth-client-credentials"
                                               :params {:token_url "https://a/token"
                                                        :client_id "c"
                                                        :client_secret "s"}}
                                              {})
                          saved (auth.load-token profile)]
                      (clean-token profile)
                      (assert.are.same {:authorization "Bearer fresh"} h)
                      (assert.are.equal 1 (length calls))
                      (assert.is_nil (: (. calls 1 :raw-body) :find "r-old" 1
                                        true))
                      (assert.are.equal "https://a/token c" saved.issuer)))))
            (it "authenticates again when a refresh fails"
                (fn []
                  (let [(http calls) (seq-mock (err-resp {:error "invalid_grant"})
                                               (ok-resp (json-body {:access_token "fresh"})))
                        auth (reload-auth http)
                        profile (tmp-profile)
                        err []
                        real-stderr io.stderr]
                    (auth.save-token profile
                                     {:access_token "old"
                                      :expires_at 1
                                      :refresh_token "r1"
                                      :issuer "https://a/token c"})
                    (set io.stderr {:write (fn [_ s] (table.insert err s))})
                    (let [(ok h) (pcall auth.get-headers profile
                                        {:name "oauth-client-credentials"
                                         :params {:token_url "https://a/token"
                                                  :client_id "c"}}
                                        {})]
                      (set io.stderr real-stderr)
                      (clean-token profile)
                      (assert.is_true ok h)
                      (assert.are.same {:authorization "Bearer fresh"} h)
                      (assert.are.equal 2 (length calls))
                      (assert.are.equal "Refreshing token...\nToken refresh failed, re-authenticating...\n"
                                        (table.concat err))))))))

;; ---- device authorization ----

(describe "oauth-device-authorization"
          (fn []
            (it "displays user_code and polls until success"
                (fn []
                  (let [sleep-calls []
                        sock (mock-socket (fn [n] (table.insert sleep-calls n)))
                        (http calls) (seq-mock (ok-resp (json-body {:device_code "dcode"
                                                                    :user_code "ABCD-1234\27]0;x\7"
                                                                    :verification_uri "https://example.com/activate"
                                                                    :expires_in 300
                                                                    :interval 5}))
                                               (err-resp (json-body {:error "authorization_pending"})
                                                         400)
                                               (ok-resp (json-body {:access_token "device-tok"
                                                                    :expires_in 3600})))
                        auth (reload-auth http sock)
                        profile (tmp-profile)
                        stderr-buf []
                        orig-stderr io.stderr]
                    (set io.stderr
                         {:write (fn [_ s] (table.insert stderr-buf s))})
                    (auth.authenticate profile
                                       {:name "oauth-device-authorization"
                                        :params {:device_authorization_url "https://auth.example.com/device"
                                                 :token_url "https://auth.example.com/token"
                                                 :client_id "my-client"}}
                                       {})
                    (set io.stderr orig-stderr)
                    (clean-token profile)
                    (assert.are.equal 3 (length calls))
                    ;; sleep happens before each poll, so 2 polls = 2 sleeps
                    (assert.are.equal 2 (length sleep-calls))
                    (assert.are.equal 5 (. sleep-calls 1))
                    (let [stderr (table.concat stderr-buf)]
                      (assert.is_truthy (stderr:find "ABCD-1234" 1 true))
                      ;; the server's text can't drive the terminal
                      (assert.is_nil (stderr:find "\27" 1 true))))))
            (it "applies slow_down backoff"
                (fn []
                  (let [sleep-calls []
                        sock (mock-socket (fn [n] (table.insert sleep-calls n)))
                        (http) (seq-mock (ok-resp (json-body {:device_code "dc"
                                                              :user_code "X"
                                                              :verification_uri "https://x.com"
                                                              :expires_in 300
                                                              :interval 5}))
                                         (err-resp (json-body {:error "slow_down"})
                                                   400)
                                         (ok-resp (json-body {:access_token "tok"
                                                              :expires_in 3600})))
                        auth (reload-auth http sock)
                        profile (tmp-profile)
                        orig-stderr io.stderr]
                    (set io.stderr {:write (fn [_ _] nil)})
                    (auth.authenticate profile
                                       {:name "oauth-device-authorization"
                                        :params {:device_authorization_url "https://a.com/d"
                                                 :token_url "https://a.com/t"
                                                 :client_id "c"}}
                                       {})
                    (set io.stderr orig-stderr)
                    (clean-token profile)
                    (assert.are.equal 2 (length sleep-calls))
                    (assert.are.equal 5 (. sleep-calls 1))
                    (assert.are.equal 10 (. sleep-calls 2)))))
            (it "sends the client secret when there is one"
                (fn []
                  (let [sock (mock-socket)
                        (http calls) (seq-mock (ok-resp (json-body {:device_code "dc"
                                                                    :user_code "X"
                                                                    :verification_uri "https://x.com"
                                                                    :expires_in 300
                                                                    :interval 5}))
                                               (ok-resp (json-body {:access_token "tok"})))
                        auth (reload-auth http sock)
                        profile (tmp-profile)
                        orig-stderr io.stderr]
                    (set io.stderr {:write (fn [_ _] nil)})
                    (auth.authenticate profile
                                       {:name "oauth-device-authorization"
                                        :params {:device_authorization_url "https://a.com/d"
                                                 :token_url "https://a.com/t"
                                                 :client_id "c"
                                                 :client_secret "S3"}}
                                       {})
                    (set io.stderr orig-stderr)
                    (clean-token profile)
                    (each [_ call (ipairs calls)]
                      (assert.is_truthy (call.raw-body:find "client_secret=S3"
                                                            1 true))))))
            (it "keeps polling when pending comes as HTTP 200"
                (fn []
                  (let [sock (mock-socket)
                        (http calls) (seq-mock (ok-resp (json-body {:device_code "dc"
                                                                    :user_code "X"
                                                                    :verification_uri "https://x.com"
                                                                    :expires_in 300
                                                                    :interval 5}))
                                               (ok-resp (json-body {:error "authorization_pending"}))
                                               (ok-resp (json-body {:access_token "tok"})))
                        auth (reload-auth http sock)
                        profile (tmp-profile)
                        orig-stderr io.stderr]
                    (set io.stderr {:write (fn [_ _] nil)})
                    (let [(ok err) (pcall auth.authenticate profile
                                          {:name "oauth-device-authorization"
                                           :params {:device_authorization_url "https://a.com/d"
                                                    :token_url "https://a.com/t"
                                                    :client_id "c"}}
                                          {})]
                      (set io.stderr orig-stderr)
                      (clean-token profile)
                      (assert.is_true ok err)
                      (assert.are.equal 3 (length calls))))))
            (it "stops on any other token error, with its description"
                (fn []
                  (let [sock (mock-socket)
                        (http calls) (seq-mock (ok-resp (json-body {:device_code "dc"
                                                                    :user_code "X"
                                                                    :verification_uri "https://x.com"
                                                                    :expires_in 300
                                                                    :interval 5}))
                                               (err-resp (json-body {:error "invalid_client"
                                                                     :error_description "unknown client"})
                                                         401)
                                               (ok-resp (json-body {:access_token "tok"})))
                        auth (reload-auth http sock)
                        profile (tmp-profile)
                        orig-stderr io.stderr]
                    (set io.stderr {:write (fn [_ _] nil)})
                    (let [(ok err) (pcall auth.authenticate profile
                                          {:name "oauth-device-authorization"
                                           :params {:device_authorization_url "https://a.com/d"
                                                    :token_url "https://a.com/t"
                                                    :client_id "c"}}
                                          {})]
                      (set io.stderr orig-stderr)
                      (clean-token profile)
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find
                                           "invalid_client — unknown client" 1
                                           true))
                      (assert.are.equal 2 (length calls))))))
            (it "errors on expired_token"
                (fn []
                  (let [sock (mock-socket)
                        (http) (seq-mock (ok-resp (json-body {:device_code "dc"
                                                              :user_code "X"
                                                              :verification_uri "https://x.com"
                                                              :expires_in 300
                                                              :interval 5}))
                                         (err-resp (json-body {:error "expired_token"})
                                                   400))
                        auth (reload-auth http sock)
                        profile (tmp-profile)
                        orig-stderr io.stderr]
                    (set io.stderr {:write (fn [_ _] nil)})
                    (assert.has.error (fn []
                                        (auth.authenticate profile
                                                           {:name "oauth-device-authorization"
                                                            :params {:device_authorization_url "https://a.com/d"
                                                                     :token_url "https://a.com/t"
                                                                     :client_id "c"}}
                                                           {}))
                                      "device code expired")
                    (set io.stderr orig-stderr)
                    (clean-token profile))))
            (it "errors on access_denied"
                (fn []
                  (let [sock (mock-socket)
                        (http) (seq-mock (ok-resp (json-body {:device_code "dc"
                                                              :user_code "X"
                                                              :verification_uri "https://x.com"
                                                              :expires_in 300
                                                              :interval 5}))
                                         (err-resp (json-body {:error "access_denied"})
                                                   400))
                        auth (reload-auth http sock)
                        profile (tmp-profile)
                        orig-stderr io.stderr]
                    (set io.stderr {:write (fn [_ _] nil)})
                    (assert.has.error (fn []
                                        (auth.authenticate profile
                                                           {:name "oauth-device-authorization"
                                                            :params {:device_authorization_url "https://a.com/d"
                                                                     :token_url "https://a.com/t"
                                                                     :client_id "c"}}
                                                           {}))
                                      "device authorization denied by user")
                    (set io.stderr orig-stderr)
                    (clean-token profile))))
            (it "errors when device_authorization_url is missing"
                (fn []
                  (let [(http) (seq-mock)
                        auth (reload-auth http (mock-socket))
                        profile (tmp-profile)]
                    (assert.has.error (fn []
                                        (auth.authenticate profile
                                                           {:name "oauth-device-authorization"
                                                            :params {:token_url "https://a.com/t"
                                                                     :client_id "c"}}
                                                           {}))))))))

;; ---- external tool ----

(describe "external-tool auth"
          (fn []
            (it "bearer-token mode: injects Authorization header from command output"
                (fn []
                  (let [(http) (seq-mock)
                        auth (reload-auth http)
                        headers (auth.get-headers "test-profile"
                                                  {:name "external-tool"
                                                   :params {:commandline "echo 'my-token'"
                                                            :output "bearer-token"}}
                                                  {})]
                    (assert.are.equal "Bearer my-token" headers.authorization))))
            (it "runs a commandline that ends with a comment"
                (fn []
                  (let [(http) (seq-mock)
                        auth (reload-auth http)
                        headers (auth.get-headers "test-profile"
                                                  {:name "external-tool"
                                                   :params {:commandline "echo tok # from the vault"
                                                            :output "bearer-token"}}
                                                  {})]
                    (assert.are.equal "Bearer tok" headers.authorization))))
            (it "doesn't give the tool ezu's own stdin"
                (fn []
                  ;; under ezu mcp, stdin carries the protocol
                  (let [script "local a = require(\"ezu.auth\"); local h = a[\"get-headers\"](\"p\", {name = \"external-tool\", params = {commandline = \"head -c 6; echo tok\", output = \"bearer-token\"}}, {}); io.write(h.authorization)"
                        h (io.popen (.. "printf secret | lua -e '" script "'"))
                        out (h:read :*a)]
                    (h:close)
                    (assert.are.equal "Bearer tok" out))))
            (it "bearer-token mode: trims whitespace from command output"
                (fn []
                  (let [(http) (seq-mock)
                        auth (reload-auth http)
                        headers (auth.get-headers "test-profile"
                                                  {:name "external-tool"
                                                   :params {:commandline "printf '  spaced-token  '"
                                                            :output "bearer-token"}}
                                                  {})]
                    (assert.are.equal "Bearer spaced-token"
                                      headers.authorization))))
            (it "bearer-token mode: errors when command produces no output"
                (fn []
                  (let [(http) (seq-mock)
                        auth (reload-auth http)]
                    (assert.has.error (fn []
                                        (auth.get-headers "test-profile"
                                                          {:name "external-tool"
                                                           :params {:commandline "true"
                                                                    :output "bearer-token"}}
                                                          {}))))))
            (it "signing mode: get-headers returns empty table"
                (fn []
                  (let [(http) (seq-mock)
                        auth (reload-auth http)
                        headers (auth.get-headers "test-profile"
                                                  {:name "external-tool"
                                                   :params {:commandline "echo '{}'"}}
                                                  {})]
                    (assert.are.same {} headers))))
            (it "signing mode: wrap-http-fn injects headers from tool output"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp {}))
                        auth (reload-auth http)
                        base-fn (?. http :request)
                        wrapped (auth.wrap-http-fn {:name "external-tool"
                                                    :params {:commandline "echo '{\"headers\":{\"x-sig\":[\"abc\"]}}'"}}
                                                   base-fn)]
                    (assert.is_function wrapped)
                    (wrapped {:method "GET"
                              :url "https://api.example.com/items"
                              :headers {}})
                    (assert.are.equal "abc" (?. calls 1 :headers :x-sig)))))
            (it "signing mode: wrap-http-fn returns nil for bearer-token output mode"
                (fn []
                  (let [(http) (seq-mock)
                        auth (reload-auth http)
                        wrapped (auth.wrap-http-fn {:name "external-tool"
                                                    :params {:commandline "echo tok"
                                                             :output "bearer-token"}}
                                                   (fn [] nil))]
                    (assert.is_nil wrapped))))))

;; ---- unsupported auth type ----

(describe "authenticate"
          (fn []
            (it "errors on unknown auth type"
                (fn []
                  (let [(http) (seq-mock)
                        auth (reload-auth http)]
                    (assert.has.error (fn []
                                        (auth.authenticate "p"
                                                           {:name "magic-auth"
                                                            :params {}}
                                                           {}))))))))

;; ---- request signing ----

(describe "plugin signing"
          (fn []
            (it "signs the request that goes on the wire with the plugin's function"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp {}))
                        auth (reload-auth http)
                        seen {}
                        wrapped (auth.wrap-http-fn {:name "exo"
                                                    :params {:key "k1"}
                                                    :sign (fn [req params ezu]
                                                            (set seen.req req)
                                                            (set seen.params
                                                                 params)
                                                            (set seen.ezu ezu)
                                                            {:headers {:authorization (.. "SIG "
                                                                                          req.method
                                                                                          " "
                                                                                          req.url
                                                                                          " "
                                                                                          req.body)}})}
                                                   http.request)]
                    (wrapped {:method "POST"
                              :url "https://api.example.com/items"
                              :query {:b "2" :a "x y"}
                              :headers {:content-type "application/json"}
                              :body {:n 1}})
                    (assert.are.equal "https://api.example.com/items?a=x%20y&b=2"
                                      seen.req.url)
                    (assert.are.equal "{\"n\":1}" seen.req.body)
                    (assert.are.equal "k1" seen.params.key)
                    (assert.are.equal :function (type seen.ezu.hmac_sha256))
                    (assert.are.equal "SIG POST https://api.example.com/items?a=x%20y&b=2 {\"n\":1}"
                                      (. calls 1 :headers :authorization))
                    ;; what the plugin adds is a credential
                    (assert.is_truthy (accumulate [found false _ n (ipairs (. calls
                                                                              1
                                                                              :sensitive-headers))]
                                        (or found (= n :authorization)))))))
            (it "reads env: parameters when it signs"
                (fn []
                  (let [(http) (seq-mock (ok-resp {}))
                        auth (reload-auth http)
                        seen {}
                        wrapped (auth.wrap-http-fn {:name "exo"
                                                    :params {:home "env:HOME"}
                                                    :sign (fn [_ params]
                                                            (set seen.home
                                                                 params.home)
                                                            {:headers {}})}
                                                   http.request)]
                    (wrapped {:method "GET"
                              :url "https://api.example.com/"
                              :headers {}})
                    (assert.are.equal (os.getenv :HOME) seen.home))))
            (it "refuses to send a request the plugin failed to sign"
                (fn []
                  (each [_ sign (ipairs [#(error "no secret")
                                         #"not a table"
                                         #{:headers "no"}])]
                    (let [(http calls) (seq-mock (ok-resp {}))
                          auth (reload-auth http)
                          wrapped (auth.wrap-http-fn {:name "exo" : sign}
                                                     http.request)
                          (ok err) (pcall wrapped
                                          {:method "GET"
                                           :url "https://api.example.com/"
                                           :headers {}})]
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring (or (?. err :message) err))
                                           :find "auth plugin 'exo'" 1 true))
                      (assert.are.equal 0 (length calls))))))
            (it "sends the headers it adds with lowercase names"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp {}))
                        auth (reload-auth http)
                        wrapped (auth.wrap-http-fn {:name "exo"
                                                    :sign #{:headers {:Authorization "x"}}}
                                                   http.request)]
                    (wrapped {:method "GET"
                              :url "https://api.example.com/"
                              :headers {:authorization "profile"}})
                    (assert.are.same {:authorization "x"} (. calls 1 :headers)))))
            (it "keep the path parameters of a URL it parses"
                (fn []
                  (let [(http) (seq-mock (ok-resp {}))
                        auth (reload-auth http)
                        seen {}
                        wrapped (auth.wrap-http-fn {:name "exo"
                                                    :sign (fn [req _ ezu]
                                                            (set seen.url
                                                                 (ezu.url.parse req.url))
                                                            {:headers {}})}
                                                   http.request)]
                    (wrapped {:method "GET"
                              :url "https://api.example.com/v2/a;x=1/c?q=1"
                              :headers {}})
                    (assert.are.equal "/v2/a;x=1/c" seen.url.path)
                    (assert.are.equal "q=1" seen.url.query))))
            (it "is never a value from the configuration: JSON has no functions"
                (fn []
                  (let [auth (reload-auth real-http)
                        cfg {:name "bearer" :params {:token "t"} :sign true}]
                    (assert.are.same {:authorization "Bearer t"}
                                     (auth.get-headers "p" cfg {})))))
            (it "has no header to add up front, and no parameter it requires"
                (fn []
                  (let [auth (reload-auth real-http)]
                    (assert.are.same []
                                     (auth.header-names {:name "exo" :sign #{}}))
                    (assert.are.same {}
                                     (auth.get-headers "p"
                                                       {:name "exo" :sign #{}}
                                                       {})))))))

(describe "external-tool signing"
          (fn []
            (it "signs and sends the full URL including the query string"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp {}))
                        auth (reload-auth http)
                        input (os.tmpname)
                        wrapped (auth.wrap-http-fn {:name "external-tool"
                                                    :params {:commandline (.. "cat > "
                                                                              input
                                                                              "; echo '{}'")}}
                                                   http.request)]
                    (wrapped {:method "GET"
                              :url "https://api.example.com/items"
                              :query {:b "2" :a "x y"}
                              :headers {}})
                    (let [f (io.open input)
                          signed (json.decode (f:read :*a))]
                      (f:close)
                      (os.remove input)
                      (assert.are.equal "https://api.example.com/items?a=x%20y&b=2"
                                        signed.uri)
                      (assert.are.equal "https://api.example.com/items?a=x%20y&b=2"
                                        (. calls 1 :url))
                      (assert.is_nil (. calls 1 :query))))))
            (it "signs the query in its declared style"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp {}))
                        auth (reload-auth http)
                        wrapped (auth.wrap-http-fn {:name "external-tool"
                                                    :params {:commandline "echo '{}'"}}
                                                   http.request)]
                    (wrapped {:method "GET"
                              :url "https://api.example.com/items"
                              :query {:filter {:a "1"}}
                              :query-styles {:filter {:style "deepObject"
                                                      :explode true}}
                              :headers {}})
                    (assert.are.equal "https://api.example.com/items?filter[a]=1"
                                      (. calls 1 :url)))))
            (it "refuses to send a request the tool failed to sign"
                (fn []
                  (each [_ commandline (ipairs ["exit 3"
                                                "echo not-json"
                                                "true"
                                                "echo '{\"headers\":{\"x\":\"y\"}}'; exit 1"])]
                    (let [(http calls) (seq-mock (ok-resp {}))
                          auth (reload-auth http)
                          wrapped (auth.wrap-http-fn {:name "external-tool"
                                                      :params {: commandline}}
                                                     http.request)
                          (ok err) (pcall wrapped
                                          {:method "GET"
                                           :url "https://api.example.com/items"
                                           :headers {}})]
                      (assert.is_false ok commandline)
                      (assert.is_truthy (: (tostring err) :find
                                           "external auth command" 1 true))
                      (assert.are.equal 0 (length calls))))))
            (it "omits the body only when omitbody is true or \"true\""
                (fn []
                  (each [_ [omitbody expected] (ipairs [["false" "{\"n\":1}"]
                                                        ["true" ""]
                                                        ["TRUE" ""]
                                                        [true ""]])]
                    (let [(http) (seq-mock (ok-resp {}))
                          auth (reload-auth http)
                          input (os.tmpname)
                          wrapped (auth.wrap-http-fn {:name "external-tool"
                                                      :params {:commandline (.. "cat > "
                                                                                input
                                                                                "; echo '{}'")
                                                               : omitbody}}
                                                     http.request)]
                      (wrapped {:method "POST"
                                :url "https://api.example.com/items"
                                :headers {:content-type "application/json"}
                                :body {:n 1}})
                      (let [signed (with-open [f (io.open input)]
                                     (json.decode (f:read :*a)))]
                        (os.remove input)
                        (assert.are.equal expected signed.body
                                          (tostring omitbody)))))))
            (it "fails at once, without retries, on a request it can't build"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp {}))
                        auth (reload-auth http)
                        wrapped (auth.wrap-http-fn {:name "external-tool"
                                                    :params {:commandline "echo '{}'"}}
                                                   http.request)
                        (ok err) (pcall wrapped
                                        {:method "POST"
                                         :url "https://api.example.com/items"
                                         :headers {:x-a "a\nb"}
                                         :body {:n 1}})]
                    (assert.is_false ok)
                    (assert.is_true (?. err :permanent))
                    (assert.are.equal 0 (length calls)))))
            (it "marks the headers the tool adds as sensitive"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp {}))
                        auth (reload-auth http)
                        wrapped (auth.wrap-http-fn {:name "external-tool"
                                                    :params {:commandline "echo '{\"headers\": {\"X-Hmac\": [\"s\"]}}'"}}
                                                   http.request)]
                    (wrapped {:method "GET"
                              :url "https://api.example.com/x"
                              :headers {}})
                    (assert.are.same ["x-hmac"] (. calls 1 :sensitive-headers)))))
            (it "signs the encoded body and leaves the caller's request alone"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp {}))
                        auth (reload-auth http)
                        input (os.tmpname)
                        wrapped (auth.wrap-http-fn {:name "external-tool"
                                                    :params {:commandline (.. "cat > "
                                                                              input
                                                                              "; echo '{\"headers\": {\"x-sig\": [\"s1\"]}}'")}}
                                                   http.request)
                        req {:method "POST"
                             :url "https://api.example.com/items"
                             :query {:a "1"}
                             :headers {:content-type "application/json"}
                             :body {:n 1}}]
                    (wrapped req)
                    (let [f (io.open input)
                          signed (json.decode (f:read :*a))]
                      (f:close)
                      (os.remove input)
                      (assert.are.equal "{\"n\":1}" signed.body)
                      (assert.are.equal "{\"n\":1}" (. calls 1 :raw-body))
                      (assert.are.equal "s1" (. calls 1 :headers :x-sig))
                      (assert.are.same {:method "POST"
                                        :url "https://api.example.com/items"
                                        :query {:a "1"}
                                        :headers {:content-type "application/json"}
                                        :body {:n 1}}
                                       req)))))))

;; ---- authorization code callback ----

(fn send-to [port lines]
  (let [socket (require :socket)
        c (assert (socket.connect "127.0.0.1" port))]
    (c:send (.. (table.concat lines "\r\n") "\r\n\r\n"))
    c))

(describe "oauth callback listener"
          (fn []
            (it "url-decodes the authorization code"
                (fn []
                  (let [auth (reload-auth (pick-values 1 (seq-mock)))
                        (srv port) (auth.start-local-server)
                        c (send-to port
                                   ["GET /callback?code=4%2F0Ab%2Bc&state=S1 HTTP/1.1"
                                    "Host: x"])]
                    (assert.are.equal "4/0Ab+c"
                                      (auth.wait-for-callback srv "S1"
                                                              "/callback"))
                    (c:close))))
            (it "ignores requests to other paths"
                (fn []
                  (let [auth (reload-auth (pick-values 1 (seq-mock)))
                        (srv port) (auth.start-local-server)
                        c1 (send-to port
                                    ["GET /favicon.ico HTTP/1.1" "Host: x"])
                        c2 (send-to port
                                    ["GET /callback?code=abc&state=S1 HTTP/1.1"
                                     "Host: x"])]
                    (assert.are.equal "abc"
                                      (auth.wait-for-callback srv "S1"
                                                              "/callback"))
                    (c1:close)
                    (c2:close))))
            (it "reports provider errors"
                (fn []
                  (let [auth (reload-auth (pick-values 1 (seq-mock)))
                        (srv port) (auth.start-local-server)
                        c (send-to port
                                   ["GET /callback?error=access_denied&error_description=nope&state=S1 HTTP/1.1"])
                        (ok err) (pcall auth.wait-for-callback srv "S1"
                                        "/callback")]
                    (c:close)
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find "access_denied")))))
            (it "checks the state before reporting a provider error"
                (fn []
                  (let [auth (reload-auth (pick-values 1 (seq-mock)))
                        (srv port) (auth.start-local-server)
                        c (send-to port
                                   ["GET /callback?error=x&error_description=%1B%5B31mFAKE HTTP/1.1"])
                        (ok err) (pcall auth.wait-for-callback srv "S1"
                                        "/callback")]
                    (c:close)
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find "state mismatch"))
                    (assert.is_nil (: (tostring err) :find "FAKE" 1 true)))))
            (it "escapes control characters of a provider error"
                (fn []
                  (let [auth (reload-auth (pick-values 1 (seq-mock)))
                        (srv port) (auth.start-local-server)
                        c (send-to port
                                   ["GET /callback?error=x&error_description=%1B%5B31mFAKE&state=S1 HTTP/1.1"])
                        (ok err) (pcall auth.wait-for-callback srv "S1"
                                        "/callback")]
                    (c:close)
                    (assert.is_false ok)
                    (assert.is_nil (: (tostring err) :find "\27" 1 true))
                    (assert.is_truthy (: (tostring err) :find "FAKE" 1 true)))))
            (it "rejects a state mismatch without reporting success to the browser"
                (fn []
                  (let [auth (reload-auth (pick-values 1 (seq-mock)))
                        (srv port) (auth.start-local-server)
                        c (send-to port
                                   ["GET /callback?code=abc&state=EVIL HTTP/1.1"])
                        (ok err) (pcall auth.wait-for-callback srv "S1"
                                        "/callback")
                        reply (c:receive "*a")]
                    (c:close)
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find "state mismatch"))
                    (assert.is_nil (reply:find "successful")))))))

;; ---- authorization code request ----

(describe "oauth-authorization-code"
          (fn []
            (it "sends an S256 PKCE challenge derived from the verifier"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp (json-body {:access_token "t"})))
                        auth (reload-auth http)
                        profile (tmp-profile)
                        opened []]
                    (auth.authenticate profile
                                       {:name "oauth-authorization-code"
                                        :params {:authorize_url "https://a.example.com/authorize"
                                                 :token_url "https://a.example.com/token"
                                                 :client_id "cid"}}
                                       {}
                                       {:open-browser (fn [url]
                                                        (table.insert opened
                                                                      url)
                                                        (let [state (url:match "[?&]state=([^&]+)")
                                                              port (url:match "redirect_uri=http%%3A%%2F%%2F127%.0%.0%.1%%3A(%d+)")]
                                                          (: (send-to port
                                                                      [(.. "GET /callback?code=c1&state="
                                                                           state
                                                                           " HTTP/1.1")])
                                                             :close)))})
                    (clean-token profile)
                    (let [digest (require :ezu.digest)
                          challenge (: (. opened 1) :match
                                       "code_challenge=([^&]+)")
                          verifier (: (. calls 1 :raw-body) :match
                                      "code_verifier=([^&]+)")]
                      (assert.is_truthy (: (. opened 1) :find
                                           "code_challenge_method=S256" 1 true))
                      (assert.are.equal (digest.pkce-challenge verifier)
                                        challenge)
                      (assert.is_truthy (: (. calls 1 :raw-body) :find
                                           "code=c1" 1 true))))))))

;; ---- refresh ----

(describe "token refresh"
          (fn []
            (it "sends client_secret and keeps the old refresh token when none is returned"
                (fn []
                  (let [(http calls) (seq-mock (ok-resp (json-body {:access_token "new"
                                                                    :expires_in 60})))
                        auth (reload-auth http)
                        profile (tmp-profile)
                        cfg {:name "oauth-client-credentials"
                             :params {:token_url "https://a.example.com/token"
                                      :client_id "cid"
                                      :client_secret "sec"}}]
                    (auth.save-token profile
                                     {:access_token "old"
                                      :expires_at 1
                                      :refresh_token "r1"
                                      :issuer "https://a.example.com/token cid"})
                    (assert.are.same {:authorization "Bearer new"}
                                     (auth.get-headers profile cfg {}))
                    (let [saved (auth.load-token profile)]
                      (clean-token profile)
                      (assert.is_truthy (: (. calls 1 :raw-body) :find
                                           "client_secret=sec" 1 true))
                      (assert.is_truthy (: (. calls 1 :raw-body) :find
                                           "grant_type=refresh_token" 1 true))
                      (assert.are.equal "r1" saved.refresh_token)))))))

;; ---- token storage ----

(describe "token storage"
          (fn []
            (it "keeps profile names inside the token directory"
                (fn []
                  (let [auth (reload-auth (pick-values 1 (seq-mock)))]
                    (assert.is_nil (: (auth.token-path "../../evil") :find
                                      "/../" 1 true)))))))

;; ---- static credentials ----

(describe "static auth types"
          (fn []
            (let [auth (reload-auth (pick-values 1 (seq-mock)))
                  home (os.getenv :HOME)]
              (it "bearer sends the token"
                  (fn []
                    (assert.are.same {:authorization "Bearer t0k"}
                                     (auth.get-headers "p"
                                                       {:name "bearer"
                                                        :params {:token "t0k"}}
                                                       {}))))
              (it "bearer reads env: values"
                  (fn []
                    (assert.are.same {:authorization (.. "Bearer " home)}
                                     (auth.get-headers "p"
                                                       {:name "bearer"
                                                        :params {:token "env:HOME"}}
                                                       {}))))
              (it "takes parameters from a command or a file"
                  (fn []
                    (assert.are.same {:authorization "Bearer from-cmd"}
                                     (auth.get-headers "p"
                                                       {:name "bearer"
                                                        :params {:token {:cmd ["printf"
                                                                               "from-cmd\n"]}}}
                                                       {}))
                    (let [path (os.tmpname)]
                      (with-open [f (io.open path :w)]
                        (f:write "from-file\n"))
                      (os.execute (.. "chmod 600 " path))
                      (let [headers (auth.get-headers "p"
                                                      {:name "basic"
                                                       :params {:username "u"
                                                                :password {:file path}}}
                                                      {})]
                        (os.remove path)
                        (assert.are.same {:authorization "Basic dTpmcm9tLWZpbGU="}
                                         headers)))))
              (it "says which parameter's source failed"
                  (fn []
                    (assert.has.error #(auth.get-headers "p"
                                                         {:name "bearer"
                                                          :params {:token {:env "EZU_NOT_SET_42"}}}
                                                         {})
                                      "params.token: environment variable EZU_NOT_SET_42 is not set")))
              (it "basic encodes username and password"
                  (fn []
                    (assert.are.same {:authorization "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ=="}
                                     (auth.get-headers "p"
                                                       {:name "basic"
                                                        :params {:username "Aladdin"
                                                                 :password "open sesame"}}
                                                       {}))))
              (it "api-key in a header"
                  (fn []
                    (assert.are.same {:x-api-key "k1"}
                                     (auth.get-headers "p"
                                                       {:name "api-key"
                                                        :params {:name "X-API-Key"
                                                                 :in "header"
                                                                 :value "k1"}}
                                                       {}))))
              (it "api-key in the query string is added to every request"
                  (fn []
                    (let [cfg {:name "api-key"
                               :params {:name "api_key"
                                        :in "query"
                                        :value "k1"}}
                          sent []
                          wrapped (auth.wrap-http-fn cfg
                                                     (fn [req]
                                                       (table.insert sent req)
                                                       {:status 200}))]
                      (assert.are.same {} (auth.get-headers "p" cfg {}))
                      (wrapped {:method "GET"
                                :url "https://x/y"
                                :query {:a "1"}})
                      (assert.are.same {:a "1" :api_key "k1"} (. sent 1 :query)))))
              (it "rejects missing parameters with a clear message"
                  (fn []
                    (let [(ok err) (pcall auth.get-headers "p"
                                          {:name "basic"
                                           :params {:username "u"}}
                                          {})]
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find
                                           "basic auth requires params.password"
                                           1 true)))))
              (it "rejects unknown auth types"
                  (fn []
                    (let [(ok err) (pcall auth.get-headers "p"
                                          {:name "magic" :params {}} {})]
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find
                                           "unsupported auth type: magic" 1 true))))))))

(describe "api-key query parameter"
          (fn []
            (it "is not added twice when the URL already carries it"
                (fn []
                  (let [auth (reload-auth (pick-values 1 (seq-mock)))
                        sent []
                        wrapped (auth.wrap-http-fn {:name "api-key"
                                                    :params {:name "api_key"
                                                             :in "query"
                                                             :value "K"}}
                                                   (fn [req]
                                                     (table.insert sent req)
                                                     {:status 200}))]
                    (wrapped {:method "GET"
                              :url "https://h/items?api_key=K&page=2"})
                    (assert.is_nil (?. sent 1 :query :api_key)))))
            (it "marks the parameter as sensitive"
                (fn []
                  (let [auth (reload-auth (pick-values 1 (seq-mock)))
                        sent []
                        wrapped (auth.wrap-http-fn {:name "api-key"
                                                    :params {:name "appid"
                                                             :in "query"
                                                             :value "K"}}
                                                   (fn [req]
                                                     (table.insert sent req)
                                                     {:status 200}))]
                    (wrapped {:method "GET" :url "https://h/items"})
                    (assert.are.same [:appid] (. sent 1 :sensitive-query)))))
            (it "leaves the caller's request alone"
                (fn []
                  (let [auth (reload-auth (pick-values 1 (seq-mock)))
                        sent []
                        wrapped (auth.wrap-http-fn {:name "api-key"
                                                    :params {:name "api_key"
                                                             :in "query"
                                                             :value "K"}}
                                                   (fn [req]
                                                     (table.insert sent req)
                                                     {:status 200}))
                        req {:method "GET" :url "https://h/items"}]
                    (wrapped req)
                    (assert.are.same {:api_key "K"} (. sent 1 :query))
                    (assert.are.same {:method "GET" :url "https://h/items"} req))))))

(describe "auth.header-names"
          (fn []
            (let [auth (reload-auth (pick-values 1 (seq-mock)))]
              (it "names the header each auth type supplies, without authenticating"
                  (fn []
                    (assert.are.same ["authorization"]
                                     (auth.header-names {:name "bearer"}))
                    (assert.are.same ["authorization"]
                                     (auth.header-names {:name "oauth-client-credentials"}))
                    (assert.are.same ["authorization"]
                                     (auth.header-names {:name "external-tool"
                                                         :params {:output "bearer-token"}}))
                    (assert.are.same ["x-api-key"]
                                     (auth.header-names {:name "api-key"
                                                         :params {:name "X-API-Key"
                                                                  :in "header"}}))
                    (assert.are.same []
                                     (auth.header-names {:name "api-key"
                                                         :params {:name "k"
                                                                  :in "query"}}))
                    (assert.are.same []
                                     (auth.header-names {:name "external-tool"
                                                         :params {}})))))))

(describe "api-key locations"
          (fn []
            (it "sends a cookie for in: cookie"
                (fn []
                  (let [auth (reload-auth (pick-values 1 (seq-mock)))
                        cfg {:name "api-key"
                             :params {:in "cookie" :name "session" :value "s3"}}]
                    (assert.are.same {:cookie "session=s3"}
                                     (auth.get-headers "p" cfg {}))
                    (assert.are.same ["cookie"] (auth.header-names cfg)))))
            (it "rejects other locations"
                (fn []
                  (let [auth (reload-auth (pick-values 1 (seq-mock)))
                        (ok err) (pcall auth.get-headers "p"
                                        {:name "api-key"
                                         :params {:in "Query"
                                                  :name "k"
                                                  :value "v"}}
                                        {})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "api-key params.in must be header, query or cookie"
                                         1 true)))))))
