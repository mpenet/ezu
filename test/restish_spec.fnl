;; ABOUTME: Specs for converting Restish configs (v1 apis.json and v2
;; ABOUTME: restish.json) into ezu profiles. Run with `make test`.
(local restish (require :ezu.cli.restish))
(local json (require :lunajson))

(fn read-json [path]
  (let [f (io.open path)
        v (json.decode (f:read :*a))]
    (f:close)
    v))

(fn has [list text]
  (accumulate [found false _ s (ipairs list) &until found]
    (not= nil (s:find text 1 true))))

(describe "restish.convert v1 (apis.json)"
          (fn []
            (let [(profiles warnings) (restish.convert (read-json "test/fixtures/restish-v1.json"))]
              (it "makes one profile per API and profile, default keeping the API name"
                  (fn []
                    (assert.are.same ["devices"
                                      "discovered"
                                      "petstore"
                                      "petstore.staging"]
                                     (doto (icollect [k (pairs profiles)] k)
                                       (table.sort)))))
              (it "maps base, spec, headers, query and tls"
                  (fn []
                    (assert.are.same {:base-url "https://api.example.com/v1"
                                      :schema "https://api.example.com/openapi.json"
                                      :headers {:X-Org "acme"}
                                      :query {:api-version "2"}
                                      :tls {:cert "/certs/client.pem"
                                            :key "/certs/client.key"
                                            :ca_cert "/certs/ca.pem"
                                            :insecure true}
                                      :auth {:name "oauth-client-credentials"
                                             :params {:client_id "pets"
                                                      :client_secret "env:PETS_SECRET"
                                                      :token_url "https://auth.example.com/token"
                                                      :scope "read write"}}}
                                     profiles.petstore)))
              (it "lets a profile override the base URL and renames http-basic"
                  (fn []
                    (assert.are.equal "https://staging.example.com/v1"
                                      (. profiles "petstore.staging" :base-url))
                    (assert.are.equal "basic"
                                      (. profiles "petstore.staging" :auth
                                         :name))
                    (assert.are.equal "env:STAGING_PW"
                                      (. profiles "petstore.staging" :auth
                                         :params :password))))
              (it "renames oauth-device-code"
                  (fn []
                    (assert.are.equal "oauth-device-authorization"
                                      profiles.devices.auth.name)))
              (it "drops empty auth"
                  (fn [] (assert.is_nil profiles.discovered.auth)))
              (it "reports what doesn't carry over"
                  (fn []
                    (assert.is_true (has warnings
                                         "devices: 2 spec_files; using the first (./devices.yaml)"))
                    ;; a base URL without spec_files: ezu finds the spec
                    ;; as Restish does
                    (assert.is_nil (accumulate [found nil _ w (ipairs warnings)
                                                &until found]
                                     (when (w:find "discovered:" 1 true) w))))))))

(describe "restish.convert v2 (restish.json)"
          (fn []
            (let [(profiles warnings) (restish.convert (read-json "test/fixtures/restish-v2.json"))]
              (it "maps base_url + operation_base and spec_url"
                  (fn []
                    (assert.are.equal "https://billing.example.com/api"
                                      profiles.billing.base-url)
                    (assert.are.equal "https://billing.example.com/openapi.yaml"
                                      profiles.billing.schema)))
              (it "leaves out server variables a base URL leaves unused"
                  (fn []
                    (assert.is_nil profiles.billing.server)
                    (assert.is_true (has warnings
                                         "billing: server_variables left out: ezu sends requests to the base URL as it is"))))
              (it "parses header and query lists"
                  (fn []
                    (assert.are.same {:X-Team "core" :X-Trace "on"}
                                     profiles.billing.headers)
                    (assert.are.same {:debug "1"} profiles.billing.query)))
              (it "maps client certificates and the CA"
                  (fn []
                    (assert.are.same {:cert "/certs/c.pem"
                                      :key "/certs/c.key"
                                      :ca_cert "/certs/ca.pem"}
                                     profiles.billing.tls)))
              (it "reads the auth type and renames scopes"
                  (fn []
                    (assert.are.equal "oauth-authorization-code"
                                      profiles.billing.auth.name)
                    (assert.are.equal "openid"
                                      profiles.billing.auth.params.scope)))
              (it "resolves auth_ref against auth_profiles"
                  (fn []
                    (assert.are.same {:name "bearer"
                                      :params {:token "env:BOT_TOKEN"}}
                                     (. profiles "billing.ci" :auth))
                    (assert.are.equal "https://ci.example.com/api"
                                      (. profiles "billing.ci" :base-url))))
              (it "reports what doesn't carry over"
                  (fn []
                    (assert.is_true (has warnings
                                         "billing: uses issuer_url (OIDC discovery); set authorize_url and token_url"))
                    (assert.is_true (has warnings
                                         "billing: url_overrides are not supported"))
                    (assert.is_true (has warnings
                                         "billing.multi: credentials are not supported; add an auth block")))))))

(describe "restish.find-config"
          (fn []
            (it "prefers restish.json over apis.json in the same directory"
                (fn []
                  (let [found (restish.find-config {:RSH_CONFIG_DIR "/r"}
                                                   "/home/u"
                                                   #(or (= $ "/r/restish.json")
                                                        (= $ "/r/apis.json")))]
                    (assert.are.equal "/r/restish.json" found))))
            (it "falls back through XDG, ~/.config, macOS and ~/.restish locations"
                (fn []
                  (assert.are.equal "/home/u/Library/Application Support/restish/apis.json"
                                    (restish.find-config {} "/home/u"
                                                         #(= $
                                                             "/home/u/Library/Application Support/restish/apis.json")))
                  (assert.are.equal "/home/u/.restish/apis.json"
                                    (restish.find-config {} "/home/u"
                                                         #(= $
                                                             "/home/u/.restish/apis.json")))
                  (assert.is_nil (restish.find-config {} "/home/u" #false))))))

(describe "restish.convert with unexpected shapes"
          (fn []
            (it "rejects a config that is not an object"
                (fn []
                  (let [json (require :ezu.json)
                        (ok err) (pcall restish.convert (json.array [1 2]))]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "not a Restish configuration" 1 true)))))
            (it "maps server variables without a base URL"
                (fn []
                  (let [(profiles warnings) (restish.convert {:apis {:a {:spec_files ["/a.json"]
                                                                         :server_variables {:zone "x"
                                                                                            :env "pp"}
                                                                         :profiles {:default {:server_variables {:zone "y"}}}}}})]
                    (assert.are.same {:zone "y" :env "pp"} profiles.a.server)
                    (assert.are.same [] warnings))))
            (it "skips entries that are not what Restish writes"
                (fn []
                  (let [json (require :ezu.json)
                        (profiles warnings) (restish.convert {:apis {:a {:base "https://a"
                                                                         :profiles {:default {:headers (json.array [5
                                                                                                                    "x: 1"])}}}
                                                                     :b 7}})]
                    (assert.are.same {:x "1"} profiles.a.headers)
                    (assert.is_nil profiles.b)
                    (assert.is_truthy (: (table.concat warnings "\n") :find
                                         "b: not an API definition" 1 true)))))))

(describe "restish.convert auth details"
          (fn []
            (let [convert #(restish.convert {:apis {:a {:base "https://a"
                                                        :profiles {:default {:auth $}}}}})]
              (it "uses Restish's redirect address for authorization code logins"
                  (fn []
                    (let [profiles (convert {:type "oauth-authorization-code"
                                             :params {:client_id "c"
                                                      :authorize_url "https://i/a"
                                                      :token_url "https://i/t"}})]
                      (assert.are.same {:client_id "c"
                                        :authorize_url "https://i/a"
                                        :token_url "https://i/t"
                                        :redirect_host "localhost"
                                        :redirect_port 8484
                                        :redirect_path "/"}
                                       profiles.a.auth.params))
                    (let [profiles (convert {:type "oauth-authorization-code"
                                             :params {:client_id "c"
                                                      :redirect_url "http://127.0.0.1:9000/cb"}})]
                      (assert.are.same {:client_id "c"
                                        :redirect_host "127.0.0.1"
                                        :redirect_port 9000
                                        :redirect_path "/cb"}
                                       profiles.a.auth.params))))
              (it "warns about an IPv6 redirect_url and uses the defaults"
                  (fn []
                    (let [(profiles warnings) (convert {:type "oauth-authorization-code"
                                                        :params {:client_id "c"
                                                                 :redirect_url "http://[::1]:8484/cb"}})]
                      (assert.are.equal "localhost"
                                        profiles.a.auth.params.redirect_host)
                      (assert.are.equal 8484
                                        profiles.a.auth.params.redirect_port)
                      (assert.is_truthy (: (table.concat warnings "\n") :find
                                           "redirect_url" 1 true)))))
              (it "keeps a profile's own redirect port and path"
                  (fn []
                    (let [profiles (convert {:type "oauth-authorization-code"
                                             :params {:client_id "c"
                                                      :redirect_port "9000"
                                                      :redirect_path "cb"}})]
                      (assert.are.same {:client_id "c"
                                        :redirect_host "localhost"
                                        :redirect_port 9000
                                        :redirect_path "/cb"}
                                       profiles.a.auth.params))
                    (let [profiles (convert {:type "oauth-authorization-code"
                                             :params {:client_id "c"
                                                      :redirect_url "http://localhost/cb"}})]
                      (assert.are.equal 80 profiles.a.auth.params.redirect_port))))
              (it "warns about settings ezu can't apply"
                  (fn []
                    (let [(_ warnings) (convert {:type "http-basic"
                                                 :params {:username "me"}})]
                      (assert.is_truthy (: (table.concat warnings "\n") :find
                                           "no password" 1 true)))
                    (let [(_ warnings) (convert {:type "oauth-authorization-code"
                                                 :params {:client_id "c"
                                                          :auth_method "header"}})]
                      (assert.is_truthy (: (table.concat warnings "\n") :find
                                           "auth_method" 1 true))))))))

(describe "restish.convert profile settings"
          (fn []
            (it "warns about a profile's url_overrides"
                (fn []
                  (let [(_ warnings) (restish.convert {:apis {:a {:base_url "https://a.example"
                                                                  :profiles {:default {:url_overrides {"https://a.example" "https://staging.example"}}}}}})]
                    (assert.is_truthy (: (table.concat warnings "\n") :find
                                         "url_overrides" 1 true)))))))
