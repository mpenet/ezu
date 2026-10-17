;; ABOUTME: Specs for CLI argument parsing, request building, output formatting and options.
;; ABOUTME: Run with `make test` (busted, Fennel loader).
(local cli ;; the CLI is split across modules; the specs test it as one package
       (let [merged {}]
         (each [_ m (ipairs [:ezu.cli
                             :ezu.cli.args
                             :ezu.cli.request
                             :ezu.cli.output
                             :ezu.cli.settings
                             :ezu.cli.complete])]
           (each [k v (pairs (require m))]
             (tset merged k v)))
         merged))

(describe "cli.parse-args"
          (fn []
            (it "keeps positional path params as raw strings"
                (fn []
                  (let [p (cli.parse-args ["op" "api" "get-x" "007" "1e3"])]
                    (assert.are.same ["007" "1e3"] p.path-params))))
            (it "accepts empty values"
                (fn []
                  ;; a command without option scopes, to parse every family
                  (let [p (cli.parse-args ["any"
                                           "api"
                                           "x"
                                           "--query.q="
                                           "--header.x-a="
                                           "--body.s="])]
                    (assert.are.equal "" p.query.q)
                    (assert.are.equal "" (. p.headers :x-a))
                    (assert.are.same [["s" ""]] p.body-fields))))
            (it "parses --max-gotos"
                (fn []
                  (assert.are.equal 500
                                    (. (cli.parse-args ["az"
                                                        "f"
                                                        "wf"
                                                        "--max-gotos=500"])
                                       :max-gotos))))
            (it "collects --server.NAME=VAL"
                (fn []
                  (assert.are.same {:zone "de-fra-1"}
                                   (. (cli.parse-args ["op"
                                                       "api"
                                                       "--server.zone=de-fra-1"])
                                      :server-vars))))
            (it "rejects unknown options"
                (fn []
                  (assert.has.error #(cli.parse-args ["op" "api" "--qeury.x=1"])
                                    "unknown option: --qeury.x=1")))
            (it "requires a value after -d"
                (fn []
                  (assert.has.error #(cli.parse-args ["op" "api" "mk" "-d"])
                                    "-d requires a value")))
            (it "treats everything after -- as positional"
                (fn []
                  (let [p (cli.parse-args ["op"
                                           "api"
                                           "get-x"
                                           "--"
                                           "-5"
                                           "--list"])]
                    (assert.are.same ["-5" "--list"] p.path-params)
                    (assert.is_nil p.list))))
            (it "collects --body.KEY=VAL fields as raw strings in order"
                (fn []
                  (let [p (cli.parse-args ["op"
                                           "api"
                                           "mk"
                                           "--body.a.b=007"
                                           "--body.n=5"])]
                    (assert.are.same [["a.b" "007"] ["n" "5"]] p.body-fields))))))

(describe "cli.build-body"
          (fn []
            (it "coerces fields by schema"
                (fn []
                  (let [schema {:type "object"
                                :properties {:zip {:type "string"}
                                             :n {:type "integer"}
                                             :o {:type "object"
                                                 :properties {:on {:type "boolean"}}}}}]
                    (assert.are.same {:zip "007" :n 5 :o {:on true}}
                                     (cli.build-body [["zip" "007"]
                                                      ["n" "5"]
                                                      ["o.on" "true"]]
                                                     schema)))))
            (it "falls back to JSON literal rules without schema"
                (fn []
                  (assert.are.same {:a "007" :b 5}
                                   (cli.build-body [["a" "007"] ["b" "5"]] nil))))
            (it "builds lists from repeated fields, each item typed"
                (fn []
                  (let [schema {:type "object"
                                :properties {:tags {:type "array"
                                                    :items {:type "string"}}
                                             :ids {:type "array"
                                                   :items {:type "integer"}}
                                             :o {:type "object"
                                                 :properties {:l {:type "array"}}}}}]
                    (assert.are.same {:tags ["a" "007"] :ids [1 2] :o {:l [3]}}
                                     (cli.build-body [["tags" "a"]
                                                      ["ids" "1"]
                                                      ["tags" "007"]
                                                      ["ids" "2"]
                                                      ["o.l" "3"]]
                                                     schema))
                    ;; a JSON array is the whole list
                    (assert.are.same {:tags ["x" "y"]}
                                     (cli.build-body [["tags" "[\"x\", \"y\"]"]]
                                                     schema))
                    ;; an item that only looks like a JSON array is an item
                    (assert.are.same {:tags ["[draft]"]}
                                     (cli.build-body [["tags" "[draft]"]]
                                                     schema))
                    ;; fields replace what the base had, rather than adding to it
                    (assert.are.same {:tags ["a"]}
                                     (cli.build-body [["tags" "a"]] schema
                                                     {:tags ["old"]})))))))

(describe "cli.op-request"
          (fn []
            (let [op {:path-params ["ownerId" "petId"] :has-body true}]
              (it "maps positional path params to names without coercion"
                  (fn []
                    (let [req (cli.op-request op
                                              {:path-params ["007" "x"]
                                               :query {}
                                               :headers {}
                                               :body-fields []})]
                      (assert.are.same {:ownerId "007" :petId "x"} req.path))))
              (it "sends no body when none is given but keeps query"
                  (fn []
                    (let [req (cli.op-request op
                                              {:path-params ["1" "2"]
                                               :query {:q "v"}
                                               :headers {}
                                               :body-fields []})]
                      (assert.is_nil req.body)
                      (assert.are.same {:q "v"} req.query))))
              (it "merges --body.KEY fields over --body"
                  (fn []
                    (let [req (cli.op-request op
                                              {:path-params ["1" "2"]
                                               :query {}
                                               :headers {}
                                               :body {:x 1}
                                               :body-fields [["y" "2"]]})]
                      (assert.are.same {:x 1 :y 2} req.body)))))))

(describe "cli.format-output"
          (fn []
            (let [resp {:status 200
                        :headers {:b "2" :a "1"}
                        :body {:x 1}
                        :raw "{\"x\": 1}"}]
              (it "raw prints the body exactly as received"
                  (fn []
                    (assert.are.equal "{\"x\": 1}"
                                      (cli.format-output resp :raw false))))
              (it "json pretty-prints"
                  (fn []
                    (assert.are.equal "{\n  \"x\": 1\n}"
                                      (cli.format-output resp :json false))))
              (it "yaml renders without leading newline"
                  (fn []
                    (assert.are.equal "x: 1"
                                      (cli.format-output resp :yaml false))))
              (it "status prints the code"
                  (fn []
                    (assert.are.equal "200"
                                      (cli.format-output resp :status false))))
              (it "headers print sorted"
                  (fn []
                    (assert.are.equal "a: 1\nb: 2"
                                      (cli.format-output resp :headers false))))
              (it "applies select"
                  (fn []
                    (assert.are.equal "1"
                                      (cli.format-output resp :json false ".x"))))
              (it "returns nil when there is no body"
                  (fn []
                    (assert.is_nil (cli.format-output {:status 204 :headers {}}
                                                      :json false))))
              (it "raw with select prints tables as compact JSON and scalars as text"
                  (fn []
                    (let [r {:status 200
                             :headers {}
                             :body {:a {:b 1} :n 2}
                             :raw "{}"}]
                      (assert.are.equal "{\n  \"b\": 1\n}"
                                        (cli.format-output r :raw false ".a"))
                      (assert.are.equal "2"
                                        (cli.format-output r :raw false ".n"))
                      (assert.is_nil (cli.format-output r :raw false ".zz")))))
              (it "raw returns nil for an empty body"
                  (fn []
                    (assert.is_nil (cli.format-output {:status 204
                                                       :headers {}
                                                       :raw ""}
                                                      :raw false)))))))

(fn capture [f]
  "Runs f with print and io.stderr captured; returns (result out err)."
  (let [out []
        err []
        real-print _G.print
        real-stderr io.stderr]
    (set _G.print (fn [s] (table.insert out (tostring s))))
    (set io.stderr {:write (fn [_ s] (table.insert err s))})
    (let [(ok result) (pcall f)]
      (set _G.print real-print)
      (set io.stderr real-stderr)
      (assert ok result)
      (values result (table.concat out "\n") (table.concat err)))))

(describe "cli.print-resp"
          (fn []
            (it "prints nothing for a dry run"
                (fn []
                  (let [(code out err) (capture #(cli.print-resp {:dry-run true
                                                                  :status 0}
                                                                 :json true))]
                    (assert.are.equal 0 code)
                    (assert.are.equal "" out)
                    (assert.are.equal "" err))))
            (it "reports an empty body on stderr"
                (fn []
                  (let [(code out err) (capture #(cli.print-resp {:status 204
                                                                  :headers {}}
                                                                 :json true))]
                    (assert.are.equal 0 code)
                    (assert.are.equal "" out)
                    (assert.are.equal "HTTP 204\n" err))))
            (it "prints status, timing and headers when verbose"
                (fn []
                  (let [(_ out err) (capture #(cli.print-resp {:status 200
                                                               :headers {:b "2"
                                                                         :a "1"}
                                                               :body {:x 1}}
                                                              :json true true
                                                              nil 0.5))]
                    (assert.are.equal "{\n  \"x\": 1\n}" out)
                    (assert.are.equal "HTTP 200  0.500s\na: 1\nb: 2\n\n" err))))
            (it "logs how long each phase of an exchange took"
                (fn []
                  (let [(_ _ err) (capture #((cli.wrap-log-request (fn [_]
                                                                     {:status 200
                                                                      :headers {}
                                                                      :timings {:namelookup 0.003
                                                                                :connect 0.02
                                                                                :appconnect 0.045
                                                                                :pretransfer 0.046
                                                                                :starttransfer 0.121
                                                                                :total 0.126}})) {:method "GET"
                                                                                                  :url "https://api.test/x"
                                                                                                  :headers {}}))]
                    (assert.is_truthy (err:find "< 200  dns 3ms · tcp 17ms · tls 25ms · server 75ms · download 5ms · total 126ms"
                                                1 true)
                                      err))))
            (it "leaves out the phases of a connection it reused"
                (fn []
                  (assert.are.equal "server 50ms · download 1ms · total 51ms"
                                    (cli.timing-text {:namelookup 0
                                                      :connect 0
                                                      :appconnect 0
                                                      :pretransfer 0.0001
                                                      :starttransfer 0.05
                                                      :total 0.051}))
                  ;; plain HTTP has no TLS handshake
                  (assert.are.equal "dns 1ms · tcp 2ms · server 7ms · total 10ms"
                                    (cli.timing-text {:namelookup 0.001
                                                      :connect 0.003
                                                      :appconnect 0
                                                      :pretransfer 0.003
                                                      :starttransfer 0.01
                                                      :total 0.01}))))
            (it "counts the time of the redirects that led to a response"
                (fn []
                  (assert.are.equal "redirects 500ms · server 20ms · total 520ms"
                                    (cli.timing-text {:namelookup 0
                                                      :connect 0
                                                      :appconnect 0
                                                      :pretransfer 0
                                                      :starttransfer 0.02
                                                      :total 0.52
                                                      :redirects 0.5}))))
            (it "logs only each exchange's line and timing with --timing"
                (fn []
                  (let [(_ _ err) (capture #((cli.wrap-log-timing (fn [_]
                                                                    {:status 404
                                                                     :headers {}
                                                                     :timings {:namelookup 0
                                                                               :connect 0
                                                                               :appconnect 0
                                                                               :pretransfer 0
                                                                               :starttransfer 0.02
                                                                               :total 0.02}})) {:method "GET"
                                                                                                :url "https://api.test/x"
                                                                                                :query {:token "s3cret"}
                                                                                                :sensitive-query [:token]
                                                                                                :headers {:authorization "Bearer no"}}))]
                    (assert.are.equal "GET https://api.test/x?token=<redacted>  404  server 20ms · total 20ms\n"
                                      err))))
            (it "logs where a redirected request ended"
                (fn []
                  (let [(_ _ err) (capture #((cli.wrap-log-request (fn [_]
                                                                     {:status 200
                                                                      :headers {}
                                                                      :url "https://login.test/auth?x=1"})) {:method "GET"
                                                                                                             :url "https://api.test/spec.json"
                                                                                                             :headers {}}))]
                    (assert.is_truthy (err:find "< redirected to https://login.test/auth?x=1"
                                                1 true)
                                      err))))
            (it "redacts credentials in the response headers it logs"
                (fn []
                  (let [(_ _ err) (capture #(cli.print-resp {:status 200
                                                             :headers {:set-cookie "session=S"
                                                                       :x-auth-token "T"}
                                                             :body {}}
                                                            :json true true))]
                    (assert.are.equal "HTTP 200\nset-cookie: <redacted>\nx-auth-token: <redacted>\n\n"
                                      err))))
            (it "sends error bodies to stderr with the exit code"
                (fn []
                  (let [(code out err) (capture #(cli.print-resp {:status 503
                                                                  :headers {}
                                                                  :body {:e 1}}
                                                                 :json true))]
                    (assert.are.equal 5 code)
                    (assert.are.equal "" out)
                    (assert.are.equal "HTTP 503\n{\n  \"e\": 1\n}\n" err))))
            (it "colours an error body only when stderr is a terminal"
                (fn []
                  ;; the tests' stderr is not a terminal
                  (let [(_ _ err) (capture #(cli.print-resp {:status 400
                                                             :headers {}
                                                             :body {:e 1}}
                                                            :json false))]
                    (assert.is_nil (err:find "\27[" 1 true)))))
            (it "prints a text error body as it is"
                (fn []
                  (let [(code _ err) (capture #(cli.print-resp {:status 404
                                                                :headers {}
                                                                :body "not found here"
                                                                :raw "not found here"}
                                                               :json true))]
                    (assert.are.equal 4 code)
                    (assert.are.equal "HTTP 404\nnot found here\n" err))))
            (it "warns when pagination stopped on an error"
                (fn []
                  (let [(_ _ err) (capture #(cli.print-resp {:status 200
                                                             :headers {}
                                                             :body [1]
                                                             :pages 2
                                                             :next-page-status 500}
                                                            :json true))]
                    (assert.are.equal "warning: stopped after 2 page(s): next page returned HTTP 500\n"
                                      err))))))

(describe "cli.client-options"
          (fn []
            (it "adds auth headers to requests on first use, not up front"
                (fn []
                  (let [sent []
                        profile {:headers {:x-api-key "k"}
                                 :auth {:name "external-tool"
                                        :params {:commandline "echo tok"
                                                 :output "bearer-token"}}}
                        opts (cli.client-options "p" profile {:ssl {} :retry 0}
                                                 {}
                                                 (fn [req]
                                                   (table.insert sent req)
                                                   {:status 200 :headers {}}))]
                    (assert.are.same {:x-api-key "k"} opts.headers)
                    (opts.http-fn {:method "GET"
                                   :url "https://h/x"
                                   :headers {:x-api-key "k"}})
                    (assert.are.equal "Bearer tok"
                                      (. sent 1 :headers :authorization)))))
            (it "prefers CLI over profile over config for timeout and base-url"
                (fn []
                  (let [opts (cli.client-options "p"
                                                 {:timeout 5
                                                  :base-url "https://profile"}
                                                 {:ssl {}
                                                  :timeout 9
                                                  :base-url "https://cli"}
                                                 {:timeout 1})]
                    (assert.are.equal 9 opts.timeout)
                    (assert.are.equal "https://cli" opts.base-url))))
            (it "does not retry authentication failures"
                (fn []
                  (let [calls []
                        opts (cli.client-options "p"
                                                 {:auth {:name "external-tool"
                                                         :params {:commandline "exit 1"
                                                                  :output "bearer-token"}}}
                                                 {:ssl {} :retry 3} {}
                                                 (fn [req]
                                                   (table.insert calls req)
                                                   {:status 200 :headers {}}))
                        socket (require :socket)
                        t0 (socket.gettime)
                        (ok err) (pcall opts.http-fn
                                        {:method "GET"
                                         :url "https://h/x"
                                         :headers {}})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "authentication failed" 1 true))
                    (assert.is_true (< (- (socket.gettime) t0) 0.5))
                    (assert.are.equal 0 (length calls)))))
            (it "lets an explicitly set header win over auth, case-insensitively"
                (fn []
                  (let [sent []
                        profile {:auth {:name "external-tool"
                                        :params {:commandline "echo tok"
                                                 :output "bearer-token"}}}
                        opts (cli.client-options "p" profile {:ssl {} :retry 0}
                                                 {}
                                                 (fn [req]
                                                   (table.insert sent req)
                                                   {:status 200 :headers {}}))]
                    (opts.http-fn {:method "GET"
                                   :url "https://h/x"
                                   :headers {:Authorization "Basic static"}})
                    (assert.are.same {:Authorization "Basic static"}
                                     (. sent 1 :headers)))))
            (it "merges profile server vars with CLI ones, CLI winning"
                (fn []
                  (let [opts (cli.client-options "p"
                                                 {:server {:zone "ch-gva-2"
                                                           :version "v2"}}
                                                 {:ssl {}
                                                  :server-vars {:zone "de-fra-1"}}
                                                 {})]
                    (assert.are.same {:zone "de-fra-1" :version "v2"}
                                     opts.server-vars))))
            (it "falls back to config timeout"
                (fn []
                  (assert.are.equal 1
                                    (. (cli.client-options nil nil {:ssl {}}
                                                           {:timeout 1})
                                       :timeout))))))

(describe "cli.redact-header"
          (fn []
            (it "keeps the auth scheme but hides credentials"
                (fn []
                  (assert.are.equal "Bearer <redacted>"
                                    (cli.redact-header "Authorization"
                                                       "Bearer abc.def"))))
            (it "hides cookies, api keys, tokens and signatures"
                (fn []
                  (each [_ name (ipairs ["cookie"
                                         "x-api-key"
                                         "X-Auth-Token"
                                         "x-amz-signature"
                                         "client-secret"])]
                    (assert.are.equal "<redacted>"
                                      (cli.redact-header name "s3cr3t")))))
            (it "leaves other headers alone"
                (fn []
                  (assert.are.equal "application/json"
                                    (cli.redact-header "content-type"
                                                       "application/json"))))))

(describe "cli.strip-location"
          (fn []
            (it "strips Lua file locations"
                (fn []
                  (assert.are.equal "boom"
                                    (cli.strip-location "./lua/ezu/cli.lua:12: boom"))))
            (it "strips chunk-name locations from the static binary"
                (fn []
                  (assert.are.equal "goto loop detected at: s1"
                                    (cli.strip-location "[string \"fnl.ezu-bin\"]:7603: goto loop detected at: s1"))))
            (it "keeps URLs with ports intact"
                (fn []
                  (assert.are.equal "GET http://h:8080/x failed: timeout"
                                    (cli.strip-location "GET http://h:8080/x failed: timeout"))))))

(describe "cli.exit-code"
          (fn []
            (it "maps status classes"
                (fn []
                  (assert.are.equal 0 (cli.exit-code 200 false))
                  (assert.are.equal 0 (cli.exit-code 304 false))
                  (assert.are.equal 4 (cli.exit-code 404 false))
                  (assert.are.equal 5 (cli.exit-code 503 false))))
            (it "returns 0 for any status with --ignore-status"
                (fn [] (assert.are.equal 0 (cli.exit-code 500 true))))
            (it "parses --ignore-status"
                (fn []
                  (assert.is_true (. (cli.parse-args ["op"
                                                      "a"
                                                      "--ignore-status"])
                                     :ignore-status))))))

(describe "cli retry options"
          (fn []
            (it "parses retry flags"
                (fn []
                  (let [p (cli.parse-args ["op"
                                           "a"
                                           "--retry=5"
                                           "--retry-unsafe"
                                           "--retry-max-wait=10"])]
                    (assert.are.equal 5 p.retry)
                    (assert.is_true p.retry-unsafe)
                    (assert.are.equal 10 p.retry-max-wait))))
            (it "defaults to 2 safe retries capped at 300s"
                (fn []
                  (assert.are.same {:attempts 2 :unsafe false :max-wait 300}
                                   (cli.retry-options nil {} {}))))
            (it "prefers CLI over profile over config"
                (fn []
                  (assert.are.same {:attempts 0 :unsafe true :max-wait 30}
                                   (cli.retry-options {:retry {:attempts 4
                                                               :unsafe true}}
                                                      {:retry 0}
                                                      {:retry {:attempts 9
                                                               :max-wait 30}}))))))

(describe "dry-run rendering"
          (fn []
            (let [req {:method "POST"
                       :url "https://h/pets"
                       :query {:dry "1"}
                       :headers {:content-type "application/json"
                                 :authorization "Bearer s3cret"}
                       :body {:name "it's"}}]
              (it "describes the request with credentials redacted"
                  (fn []
                    (assert.are.equal "POST https://h/pets?dry=1\nauthorization: Bearer <redacted>\ncontent-type: application/json\n\n{\"name\":\"it's\"}"
                                      (cli.request-text req))))
              (it "renders a runnable curl command"
                  (fn []
                    (assert.are.equal "curl -X POST 'https://h/pets?dry=1' -H 'authorization: Bearer s3cret' -H 'content-type: application/json' --data-raw '{\"name\":\"it'\\''s\"}'"
                                      (cli.curl-command req))))
              (it "refuses a body with control characters it can't quote"
                  (fn []
                    (let [(ok err) (pcall cli.curl-command
                                          {:method "POST"
                                           :url "https://h/x"
                                           :headers {:content-type "application/json"}
                                           :raw-body "{\r\n  \"a\": 1\r\n}"})]
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find "--dry-run" 1
                                           true)))))
              (it "carries the TLS options and the timeout"
                  (fn []
                    (assert.are.equal "curl -X GET 'https://h/x' -k --cert 'c.pem' --key 'k.pem' --max-time 5"
                                      (cli.curl-command {:method "GET"
                                                         :url "https://h/x"
                                                         :headers {}
                                                         :timeout 5
                                                         :ssl {:verify "none"
                                                               :certificate "c.pem"
                                                               :key "k.pem"}}))
                    (assert.are.equal "curl -X GET 'https://h/x' --cacert 'ca.pem' --capath 'cas'"
                                      (cli.curl-command {:method "GET"
                                                         :url "https://h/x"
                                                         :headers {}
                                                         :ssl {:cafile "ca.pem"
                                                               :capath "cas"}}))))
              (it "omits the body when there is none"
                  (fn []
                    (assert.are.equal "curl -X GET 'https://h/x'"
                                      (cli.curl-command {:method "GET"
                                                         :url "https://h/x"
                                                         :headers {}})))))
            (it "parses the flags"
                (fn []
                  (let [p (cli.parse-args ["op" "a" "--dry-run" "--curl"])]
                    (assert.is_true p.dry-run)
                    (assert.is_true p.curl))))))

(describe "cli body decoding"
          (fn []
            (it "parses JSON or YAML for JSON operations"
                (fn []
                  (assert.are.same {:a 1}
                                   (cli.decode-body "{\"a\": 1}"
                                                    "application/json"))
                  (assert.are.same {:a 1 :b "x"}
                                   (cli.decode-body "a: 1\nb: x\n"
                                                    "application/json"))))
            (it "parses structured input for form operations"
                (fn []
                  (assert.are.same {:a "1"}
                                   (cli.decode-body "a: \"1\""
                                                    "application/x-www-form-urlencoded"))))
            (it "rejects unparseable input for JSON operations"
                (fn []
                  (let [(ok err) (pcall cli.decode-body "{oops"
                                        "application/json")]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find "invalid body" 1
                                         true)))))
            (it "sends other content types byte-for-byte"
                (fn []
                  (assert.are.equal "\137PNG\0"
                                    (cli.decode-body "\137PNG\0" "image/png"))
                  (assert.are.equal "{not json"
                                    (cli.decode-body "{not json" "text/plain"))))
            (it "keeps --body as given when there is no requestBody content type"
                (fn []
                  (assert.are.same {:a 1} (cli.decode-body "{\"a\":1}" nil))))
            (it "reads -d values raw"
                (fn []
                  (assert.are.equal "a: 1"
                                    (. (cli.parse-args ["op"
                                                        "x"
                                                        "y"
                                                        "-d"
                                                        "a: 1"])
                                       :body))))))

(describe "cli multipart fields"
          (fn []
            (it "turns @path fields into file parts and @@ into a literal @"
                (fn []
                  (let [path (os.tmpname)
                        f (io.open path :wb)]
                    (f:write "hello")
                    (f:close)
                    (let [req (cli.op-request {:path-params []
                                               :has-body true
                                               :content-type "multipart/form-data"}
                                              {:path-params []
                                               :query {}
                                               :headers {}
                                               :body-fields [["file"
                                                              (.. "@" path)]
                                                             ["handle" "@@rex"]]})]
                      (os.remove path)
                      (assert.are.equal "hello" req.body.file.content)
                      (assert.are.equal (path:match "[^/]+$")
                                        req.body.file.filename)
                      (assert.are.equal "@rex" req.body.handle)))))))

(describe "dry-run with encoded bodies"
          (fn []
            (it "shows the multipart content type with its boundary"
                (fn []
                  (let [text (cli.request-text {:method "POST"
                                                :url "https://h/u"
                                                :headers {:content-type "multipart/form-data"}
                                                :body {:a "1"}})]
                    (assert.is_truthy (text:find "content-type: multipart/form-data; boundary=ezu-"
                                                 1 true)))))
            (it "refuses to inline binary bodies in curl"
                (fn []
                  (let [(ok err) (pcall cli.curl-command
                                        {:method "POST"
                                         :url "https://h/u"
                                         :headers {:content-type "image/png"}
                                         :body "\137PNG\0"})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "cannot inline a body with control characters"
                                         1 true)))))))

(describe "cli pagination options"
          (fn []
            (it "parses pagination flags"
                (fn []
                  (let [p (cli.parse-args ["op"
                                           "a"
                                           "--max-pages=3"
                                           "--no-paginate"])]
                    (assert.are.equal 3 p.max-pages)
                    (assert.is_true p.no-paginate))))
            (it "defaults to 25 pages"
                (fn []
                  (assert.are.same {:max-pages 25}
                                   (cli.paginate-options nil {} {}))))
            (it "prefers CLI over profile over config"
                (fn []
                  (assert.are.same {:max-pages 7}
                                   (cli.paginate-options {:max-pages 7} {}
                                                         {:max-pages 9}))
                  (assert.are.same {:max-pages 2}
                                   (cli.paginate-options {:max-pages 7}
                                                         {:max-pages 2} {}))))
            (it "is disabled by --no-paginate"
                (fn []
                  (assert.is_nil (cli.paginate-options nil {:no-paginate true}
                                                       {}))))))

(describe "JSON bodies, dry-run redaction and curl output"
          (fn []
            (it "sends valid JSON bodies byte-for-byte"
                (fn []
                  (let [op {:path-params []
                            :has-body true
                            :content-type "application/json"}
                        req #(cli.op-request op
                                             {:path-params []
                                              :query {}
                                              :headers {}
                                              :body-fields []
                                              :body $})]
                    (assert.are.equal "\"hello\"" (. (req "\"hello\"") :body))
                    (assert.are.equal "null" (. (req "null") :body))
                    (assert.are.equal "{\"n\": 12345678901234567890}"
                                      (. (req "{\"n\": 12345678901234567890}")
                                         :body)))))
            (it "converts YAML input to JSON text"
                (fn []
                  (let [op {:path-params []
                            :has-body true
                            :content-type "application/json"}
                        r (cli.op-request op
                                          {:path-params []
                                           :query {}
                                           :headers {}
                                           :body-fields []
                                           :body "a: 1"})]
                    (assert.are.same {:a 1} r.body))))
            (it "redacts secret query parameters in --dry-run"
                (fn []
                  (assert.is_truthy (: (cli.request-text {:method "GET"
                                                          :url "https://h/x"
                                                          :query {:api_key "S"}
                                                          :headers {}})
                                       :find "api_key=<redacted>" 1 true))))
            (it "uses --data-raw so a leading @ is not read as a file"
                (fn []
                  (assert.is_truthy (: (cli.curl-command {:method "POST"
                                                          :url "https://h/x"
                                                          :headers {:content-type "text/plain"}
                                                          :body "@/etc/passwd"})
                                       :find "--data-raw '@/etc/passwd'" 1 true))))))

(describe "cli server listing and choice"
          (fn []
            (it "parses --server-index and --servers"
                (fn []
                  (let [p (cli.parse-args ["op"
                                           "a"
                                           "--server-index=2"
                                           "--servers"])]
                    (assert.are.equal 2 p.server-index)
                    (assert.is_true p.servers))))
            (it "takes server-index from the profile unless given on the command line"
                (fn []
                  (assert.are.equal 2
                                    (. (cli.client-options nil
                                                           {:server-index 2}
                                                           {:ssl {}} {})
                                       :server-index))
                  (assert.are.equal 3
                                    (. (cli.client-options nil
                                                           {:server-index 2}
                                                           {:ssl {}
                                                            :server-index 3}
                                                           {})
                                       :server-index))))
            (it "formats servers, marking the selection and effective values"
                (fn []
                  (let [servers [{:url "https://api-{zone}.test/v2"
                                  :variables {:zone {:default "ch-gva-2"
                                                     :enum ["ch-gva-2"
                                                            "de-fra-1"]}}}
                                 {:url "/api"
                                  :description "relative"
                                  :variables {}}]]
                    (assert.are.equal (.. "* 1. https://api-{zone}.test/v2\n"
                                          "       zone = de-fra-1  (default: ch-gva-2; one of: ch-gva-2, de-fra-1)\n"
                                          "  2. /api — relative")
                                      (cli.format-servers servers 1
                                                          {:zone "de-fra-1"})))))
            (it "shows empty string values visibly"
                (fn []
                  (let [text (cli.format-servers [{:url "https://{env}x.test"
                                                   :variables {:env {:default ""
                                                                     :enum [""
                                                                            "pp"]}}}]
                                                 1 {})]
                    (assert.is_truthy (text:find "env = \"\"  (default: \"\"; one of: \"\", pp)"
                                                 1 true)))))))

(describe "cli short aliases"
          (fn []
            (it "accepts --q. --h. --b. like their long forms"
                (fn []
                  (let [short (cli.parse-args ["any"
                                               "a"
                                               "x"
                                               "--q.status=ok"
                                               "--h.x-trace=t"
                                               "--b.pet.name=Rex"])
                        long (cli.parse-args ["any"
                                              "a"
                                              "x"
                                              "--query.status=ok"
                                              "--header.x-trace=t"
                                              "--body.pet.name=Rex"])]
                    (assert.are.same long.query short.query)
                    (assert.are.same long.headers short.headers)
                    (assert.are.same long.body-fields short.body-fields)
                    (assert.are.same {:status "ok"} short.query))))
            (it "keeps field order across short and long forms"
                (fn []
                  (assert.are.same [["a" "1"] ["b" "2"]]
                                   (. (cli.parse-args ["op"
                                                       "a"
                                                       "x"
                                                       "--b.a=1"
                                                       "--body.b=2"])
                                      :body-fields))))
            (it "still rejects unknown dotted prefixes"
                (fn []
                  (assert.has.error #(cli.parse-args ["op" "a" "--x.y=1"])
                                    "unknown option: --x.y=1")))))

(describe "cli.check-params"
          (fn []
            (let [op {:name "list-pets"
                      :parameters [{:name "status" :in "query" :required true}
                                   {:name "limit" :in "query"}
                                   {:name "X-Org" :in "header" :required true}]}]
              (it "reports missing required query and header params"
                  (fn []
                    (let [(errors) (cli.check-params op {:query {} :headers {}})]
                      (assert.are.same ["missing required query parameter 'status' (--q.status=…)"
                                        "missing required header 'X-Org' (--h.X-Org=…)"]
                                       errors))))
              (it "accepts headers in any case, including ones from the profile"
                  (fn []
                    (let [(errors) (cli.check-params op
                                                     {:query {:status "a"}
                                                      :headers {:x-org "1"}})]
                      (assert.are.same [] errors))))
              (it "warns about undeclared query names, listing the declared ones"
                  (fn []
                    (let [(_ warnings) (cli.check-params op
                                                         {:query {:status "a"
                                                                  :stauts "b"}
                                                          :headers {:x-org "1"}})]
                      (assert.are.same ["list-pets does not declare query parameter 'stauts' (declared: limit, status)"]
                                       warnings))))
              (it "does not warn about extra headers"
                  (fn []
                    (let [(_ warnings) (cli.check-params op
                                                         {:query {:status "a"}
                                                          :headers {:x-org "1"
                                                                    :x-trace "t"}})]
                      (assert.are.same [] warnings)))))
            (it "parses --no-validate"
                (fn []
                  (assert.is_true (. (cli.parse-args ["op" "a" "--no-validate"])
                                     :no-validate))))))

(describe "cli.check-body"
          (fn []
            (let [op {:content-type "application/json"
                      :body-schema {:type "object"
                                    :required ["name"]
                                    :properties {:name {:type "string"}}}}]
              (it "validates table bodies"
                  (fn []
                    (assert.are.same ["body.name: required"]
                                     (cli.check-body op {:size 1}))))
              (it "validates JSON text bodies"
                  (fn []
                    (assert.are.same ["body.name: expected string, got integer"]
                                     (cli.check-body op "{\"name\": 1}"))))
              (it "accepts valid bodies and absent ones"
                  (fn []
                    (assert.are.same [] (cli.check-body op {:name "Rex"}))
                    (assert.are.same [] (cli.check-body op nil)))))
            (it "skips non-JSON operations"
                (fn []
                  (assert.are.same []
                                   (cli.check-body {:content-type "multipart/form-data"
                                                    :body-schema {:required ["file"]}}
                                                   {}))))))

(local completion-schema
       {:openapi "3.0.0"
        :info {}
        :servers [{:url "https://api-{zone}.test"
                   :variables {:zone {:default "a" :enum ["a" "b"]}}}]
        :paths {"/pets" {:get {:operationId "listPets"
                               :summary "List pets"
                               :parameters [{:name "status"
                                             :in "query"
                                             :schema {:enum ["available"
                                                             "sold"]}}
                                            {:name "limit" :in "query"}
                                            {:name "X-Org" :in "header"}]
                               :responses {}}
                         :post {:operationId "addPet"
                                :requestBody {:content {:application/json {:schema {:properties {:name {:type "string"}
                                                                                                 :tier {:enum ["small"
                                                                                                               "large"]}}}}}}
                                :responses {}}}}})

(local completion-ctx
       {:config {:profiles {:exo {:schema "S"} :warp {:schema "W"}}
                 :arazzo {:flows {:file "F"}}}
        :load-schema (fn [_] completion-schema)
        :load-doc (fn [_]
                    {:workflows [{:workflowId "createPet"
                                  :inputs {:properties {:zone {:enum ["z1"
                                                                      "z2"]}
                                                        :name {}}}}
                                 {:workflowId "deletePet"}]})})

(fn complete [line]
  (cli.complete-line line completion-ctx))

(describe "cli.complete-line"
          (fn []
            (it "completes subcommands"
                (fn []
                  (assert.are.same ["auth"
                                    "az"
                                    "completion"
                                    "http"
                                    "mcp"
                                    "op"
                                    "profile"]
                                   (complete ""))))
            (it "completes the operations of a spec discovery found"
                (fn []
                  (let [ctx {:config {:profiles {:disc {:base-url "https://x.test"}}}
                             :known-schema #(when (= $.base-url
                                                     "https://x.test")
                                              "D")
                             :load-schema #(when (= $ "D") completion-schema)}]
                    (assert.are.same ["add-pet" "list-pets"]
                                     (cli.complete-line "op disc " ctx)))))
            (it "completes mcp's profiles and options"
                (fn []
                  (assert.are.same ["exo"] (complete "mcp e"))
                  (assert.are.same ["--allow-writes"]
                                   (complete "mcp exo --allow"))
                  (assert.are.same [] (complete "mcp exo --sel"))))
            (it "completes http methods and http's options"
                (fn []
                  (assert.are.same ["PATCH" "POST" "PUT"] (complete "http P"))
                  (assert.are.same ["--profile="]
                                   (complete "http GET /x --prof"))
                  (assert.are.same ["--q."] (complete "http GET /x --q"))
                  (assert.are.same [] (complete "http GET /x --li"))
                  (assert.are.same [] (complete "http GET /x --no-val"))))
            (it "filters by the current word"
                (fn []
                  (assert.are.same ["auth" "az"] (complete "a"))
                  (assert.are.same ["az"] (complete "az"))))
            (it "completes profiles after op, auth and profile show"
                (fn []
                  (assert.are.same ["exo" "warp"] (complete "op "))
                  (assert.are.same ["exo"] (complete "auth e"))
                  (assert.are.same ["exo" "warp"] (complete "profile show "))))
            (it "completes operation names"
                (fn []
                  (assert.are.same ["add-pet" "list-pets"] (complete "op exo "))))
            (it "completes declared query params with the prefix as typed"
                (fn []
                  (assert.are.same ["--q.limit=" "--q.status="]
                                   (complete "op exo list-pets --q."))
                  (assert.are.same ["--query.status="]
                                   (complete "op exo list-pets --query.st"))))
            (it "completes enum values"
                (fn []
                  (assert.are.same ["--q.status=available" "--q.status=sold"]
                                   (complete "op exo list-pets --q.status="))
                  (assert.are.same ["--b.tier=large"]
                                   (complete "op exo add-pet --b.tier=l"))))
            (it "completes headers and body properties"
                (fn []
                  (assert.are.same ["--h.X-Org="]
                                   (complete "op exo list-pets --h."))
                  (assert.are.same ["--b.name=" "--b.tier="]
                                   (complete "op exo add-pet --b."))))
            (it "follows refs into other documents"
                (fn []
                  (let [base (os.tmpname)
                        spec (.. base "-api.json")
                        paths (.. base "-paths.json")]
                    (with-open [f (io.open spec :w)]
                      (f:write (.. "{\"openapi\":\"3.0.0\",\"info\":{},\"paths\":{\"/items\":{\"$ref\":\""
                                   (paths:match "([^/]+)$") "#/items\"}}}")))
                    (with-open [f (io.open paths :w)]
                      (f:write "{\"items\":{\"get\":{\"operationId\":\"listItems\",\"responses\":{}}}}"))
                    (let [ezu (require :ezu)
                          names (cli.complete-line (.. "op " spec " ")
                                                   {:config {}
                                                    :load-schema ezu.load-schema})]
                      (os.remove spec)
                      (os.remove paths)
                      (os.remove base)
                      (assert.are.same ["list-items"] names)))))
            (it "expands ~/ in spec and workflow paths as the shell does"
                (fn []
                  (let [seen []
                        ctx {:config {}
                             :load-schema (fn [src]
                                            (table.insert seen src)
                                            completion-schema)
                             :load-doc (fn [src]
                                         (table.insert seen src)
                                         {:workflows []})}]
                    (cli.complete-line "op ~/spec.json " ctx)
                    (cli.complete-line "az ~/flow.yaml " ctx)
                    (assert.are.same [(.. (os.getenv :HOME) "/spec.json")
                                      (.. (os.getenv :HOME) "/flow.yaml")]
                                     seen))))
            (it "loads a profile's schema with the profile's settings"
                (fn []
                  (let [seen []
                        ctx {:config {:profiles {:exo {:schema "S"
                                                       :cache-ttl 86400}}}
                             :load-schema (fn [src profile]
                                            (table.insert seen [src profile])
                                            completion-schema)}]
                    (cli.complete-line "op exo " ctx)
                    (assert.are.equal "S" (. seen 1 1))
                    (assert.are.equal 86400 (. seen 1 2 :cache-ttl)))))
            (it "gives up on documents a spec refers to after ctx.timeout"
                (fn []
                  (let [socket (require :socket)
                        srv (assert (socket.bind "127.0.0.1" 0))
                        (_ port) (srv:getsockname)
                        spec (.. (os.tmpname) ".json")
                        t0 (socket.gettime)]
                    (with-open [f (io.open spec :w)]
                      (f:write (.. "{\"openapi\":\"3.0.0\",\"info\":{},\"paths\":{\"/x\":{\"$ref\":\"http://127.0.0.1:"
                                   port "/p.json#/x\"}}}")))
                    (let [ezu (require :ezu)
                          names (cli.complete-line (.. "op " spec " ")
                                                   {:config {}
                                                    :timeout 0.2
                                                    :load-schema ezu.load-schema})]
                      (srv:close)
                      (os.remove spec)
                      (assert.are.same [] names)
                      (assert.is_true (< (- (socket.gettime) t0) 5))))))
            (it "takes OpenAPI 3.1 boolean schemas"
                (fn []
                  (let [ctx {:config {}
                             :load-schema (fn [_]
                                            {:openapi "3.1.0"
                                             :servers [{:url "https://h"}]
                                             :paths {"/x" {:post {:operationId "postX"
                                                                  :parameters [{:name "q"
                                                                                :in "query"
                                                                                :schema true}]
                                                                  :requestBody {:content {:application/json {:schema {:properties {:a true}}}}}
                                                                  :responses {}}}
                                                     "/y" {:post {:operationId "postY"
                                                                  :requestBody {:content {:application/json {:schema true}}}
                                                                  :responses {}}}}})}]
                    (assert.are.same ["--q.q="]
                                     (cli.complete-line "op S post-x --q." ctx))
                    (assert.are.same []
                                     (cli.complete-line "op S post-x --q.q="
                                                        ctx))
                    (assert.are.same ["--b.a="]
                                     (cli.complete-line "op S post-x --b." ctx))
                    (assert.are.same []
                                     (cli.complete-line "op S post-y --b." ctx)))))
            (it "completes the variables of the server --server-index picks"
                (fn []
                  (let [ctx {:config {}
                             :load-schema (fn [_]
                                            {:openapi "3.0.0"
                                             :servers [{:url "https://{one}.x"
                                                        :variables {:one {:default "a"}}}
                                                       {:url "https://{two}.x"
                                                        :variables {:two {:default "b"}}}]
                                             :paths {}})}]
                    (assert.are.same ["--server.two="]
                                     (cli.complete-line "op S --server-index=2 --server."
                                                        ctx))
                    (assert.are.same ["--server.two="]
                                     (cli.complete-line "op S --server-index 2 --server."
                                                        ctx)))))
            (it "completes server variables and their values"
                (fn []
                  (assert.are.same ["--server.zone="]
                                   (complete "op exo --server."))
                  (assert.are.same ["--server.zone=a" "--server.zone=b"]
                                   (complete "op exo list-pets --server.zone="))))
            (it "completes flags"
                (fn []
                  (assert.are.same ["--retry-max-wait="
                                    "--retry-unsafe"
                                    "--retry="]
                                   (complete "op exo list-pets --retr"))))
            (it "completes arazzo contexts, workflows and inputs"
                (fn []
                  (assert.are.same ["flows"] (complete "az "))
                  (assert.are.same ["createPet" "deletePet"]
                                   (complete "az flows "))
                  (assert.are.same ["name=" "zone="]
                                   (complete "az flows createPet "))
                  (assert.are.same ["zone="] (complete "az flows createPet zo"))
                  (assert.are.same ["zone=z1" "zone=z2"]
                                   (complete "az flows createPet zone="))
                  ;; an input already given isn't offered again
                  (assert.are.same ["zone="]
                                   (complete "az flows createPet name=Rex "))))
            (it "completes operations of a profile that inherits its schema"
                (fn []
                  (assert.are.same (icollect [_ e (ipairs (cli.complete-line "op exo "
                                                                             completion-ctx))]
                                     e.value)
                                   (icollect [_ e (ipairs (cli.complete-line "op child "
                                                                             {:config {:profiles {:base {:schema "S"}
                                                                                                  :child {:extends "base"}}}
                                                                              :load-schema (fn [_]
                                                                                             completion-schema)}))]
                                     e.value))))
            (it "offers only the options a command accepts"
                (fn []
                  (assert.are.same ["--dry-run" "--help"]
                                   (complete "profile import-restish x --"))
                  (assert.are.same ["--help" "--logout" "--ssl." "--timeout="]
                                   (complete "auth p --"))
                  (assert.are.same ["--help"] (complete "profile list --"))
                  (assert.is_nil (: (table.concat (complete "az f --") " ")
                                    :find "--dry-run" 1 true))))
            (it "completes shells"
                (fn []
                  (assert.are.same ["bash" "fish" "zsh"]
                                   (complete "completion "))))
            (it "returns nothing rather than failing when a schema cannot load"
                (fn []
                  (assert.are.same []
                                   (cli.complete-line "op exo "
                                                      {:config completion-ctx.config
                                                       :load-schema #(error "offline")}))))))

(describe "request log (-v)"
          (fn []
            (it "logs the full URL with secret query parameters redacted"
                (fn []
                  (let [written []
                        real io.stderr]
                    (set io.stderr {:write (fn [_ s] (table.insert written s))})
                    (let [(ok err) (pcall (cli.wrap-log-request (fn []
                                                                  {:status 200}))
                                          {:method "GET"
                                           :url "https://h/x?api_key=SECRET"
                                           :query {:page "2"}
                                           :headers {:authorization "Bearer t"}})]
                      (set io.stderr real)
                      (assert.is_true ok err)
                      (let [text (table.concat written)]
                        (assert.is_truthy (text:find "> GET https://h/x?api_key=<redacted>&page=2"
                                                     1 true))
                        (assert.is_nil (text:find "SECRET" 1 true))
                        (assert.is_nil (text:find "Bearer t" 1 true)))))))
            (it "redacts what authentication marked as sensitive"
                (fn []
                  (let [(_ _ err) (capture #((cli.wrap-log-request (fn []
                                                                     {:status 200})) {:method "GET"
                                                                                      :url "https://h/x"
                                                                                      :query {:appid "s1"
                                                                                              :page "2"}
                                                                                      :headers {:X-AppId "s2"}
                                                                                      :sensitive-headers [:x-appid]
                                                                                      :sensitive-query [:appid]}))]
                    (assert.is_nil (err:find "s1" 1 true))
                    (assert.is_nil (err:find "s2" 1 true))
                    (assert.is_truthy (err:find "page=2" 1 true)))))
            (it "logs the request body, tables as JSON"
                (fn []
                  (let [log (fn [body]
                              (let [(_ _ err) (capture #((cli.wrap-log-request (fn []
                                                                                 {:status 200})) {:method "POST"
                                                                                                  :url "https://h/x"
                                                                                                  : body}))]
                                err))]
                    (assert.are.equal "> POST https://h/x\n> body: {\"a\":1}\n"
                                      (log {:a 1}))
                    (assert.are.equal "> POST https://h/x\n> body: text\n"
                                      (log "text")))))))

(describe "explicit nulls and repeated params"
          (fn []
            (it "accepts null for a required nullable property"
                (fn []
                  (assert.are.same []
                                   (cli.check-body {:content-type "application/json"
                                                    :body-schema {:required ["a"]
                                                                  :properties {:a {:type "string"
                                                                                   :nullable true}}}}
                                                   "{\"a\": null}"))))
            (it "builds arrays from repeated query flags"
                (fn []
                  (assert.are.same {:tag ["a" "b" "c"] :one "x"}
                                   (. (cli.parse-args ["op"
                                                       "s"
                                                       "o"
                                                       "--q.tag=a"
                                                       "--query.tag=b"
                                                       "--q.tag=c"
                                                       "--q.one=x"])
                                      :query))))
            (it "joins repeated header flags"
                (fn []
                  (assert.are.same {:accept "a/b, c/d"}
                                   (. (cli.parse-args ["op"
                                                       "s"
                                                       "o"
                                                       "--h.accept=a/b"
                                                       "--h.accept=c/d"])
                                      :headers))))))

(describe "option table parsing"
          (fn []
            (it "accepts --flag VALUE as well as --flag=VALUE"
                (fn []
                  (let [p (cli.parse-args ["op"
                                           "a"
                                           "--timeout"
                                           "5"
                                           "--output"
                                           "yaml"
                                           "--retry=1"])]
                    (assert.are.equal 5 p.timeout)
                    (assert.are.equal "yaml" p.output)
                    (assert.are.equal 1 p.retry))))
            (it "rejects non-numeric values for numeric options"
                (fn []
                  (assert.has.error #(cli.parse-args ["op" "a" "--timeout=abc"])
                                    "--timeout expects a number, got 'abc'")))
            (it "rejects values on switches"
                (fn []
                  (assert.has.error #(cli.parse-args ["op" "a" "--list=yes"])
                                    "--list takes no value")))
            (it "requires a value for value options at the end of the line"
                (fn []
                  (assert.has.error #(cli.parse-args ["op" "a" "--timeout"])
                                    "--timeout requires a value")))
            (it "parses --ssl. and --server. families"
                (fn []
                  (let [p (cli.parse-args ["op"
                                           "a"
                                           "--ssl.verify=none"
                                           "--server.zone=z"])]
                    (assert.are.same {:verify "none"} p.ssl)
                    (assert.are.same {:zone "z"} p.server-vars))))
            (it "has one entry per option for usage and completion"
                (fn []
                  (let [seen {}]
                    (each [_ o (ipairs cli.options)]
                      (each [_ n (ipairs (or o.names []))]
                        (assert.is_nil (. seen n) n)
                        (tset seen n true))))))))

(describe "CLI edge cases"
          (fn []
            (it "completion skips the values of separated options"
                (fn []
                  (assert.are.same ["add-pet" "list-pets"]
                                   (complete "op --output yaml exo "))
                  (assert.are.same ["list-pets"]
                                   (complete "op --timeout 5 exo li"))))
            (it "merges repeated headers regardless of case"
                (fn []
                  (assert.are.same {:X-A "1, 2"}
                                   (. (cli.parse-args ["op"
                                                       "s"
                                                       "o"
                                                       "--h.X-A=1"
                                                       "--h.x-a=2"])
                                      :headers))))))

(describe "profile query and ca_cert"
          (fn []
            (it "adds the profile's query parameters to every request, explicit ones winning"
                (fn []
                  (let [sent []
                        opts (cli.client-options "p"
                                                 {:query {:api-version "2"
                                                          :region "eu"}}
                                                 {:ssl {} :retry 0} {}
                                                 (fn [req]
                                                   (table.insert sent req)
                                                   {:status 200 :headers {}}))]
                    (opts.http-fn {:method "GET"
                                   :url "https://h/x"
                                   :query {:region "us"}})
                    (assert.are.same {:api-version "2" :region "us"}
                                     (. sent 1 :query)))))
            (it "marks the headers authentication adds as sensitive"
                (fn []
                  (let [sent []
                        opts (cli.client-options "p"
                                                 {:auth {:name "api-key"
                                                         :params {:name "X-AppId"
                                                                  :in "header"
                                                                  :value "k"}}}
                                                 {:no-paginate true :retry 0} {}
                                                 (fn [req]
                                                   (table.insert sent req)
                                                   {:status 200 :headers {}}))]
                    (opts.http-fn {:method "GET" :url "https://h/x"})
                    (assert.are.same [:x-appid] (. sent 1 :sensitive-headers)))))
            (it "maps tls ca_cert to the cafile ssl option"
                (fn []
                  (assert.are.equal "ca.pem"
                                    (. (cli.merge-ssl {:tls {:ca_cert "ca.pem"}}
                                                      nil)
                                       :cafile))))))

(describe "profiles and settings"
          (fn []
            (it "inherits from extends, merging headers"
                (fn []
                  (let [profiles {:base {:schema "s.json"
                                         :headers {:a "1" :b "1"}
                                         :timeout 5}
                                  :child {:extends "base"
                                          :headers {:b "2"}
                                          :timeout 9}
                                  :grandchild {:extends "child"}}]
                    (assert.are.same {:schema "s.json"
                                      :headers {:a "1" :b "2"}
                                      :timeout 9}
                                     (cli.resolve-profile "grandchild" profiles)))))
            (it "lets a child's header win whatever its case"
                (fn []
                  (for [_ 1 5]
                    (let [p (cli.resolve-profile "child"
                                                 {:base {:headers {:Authorization "Bearer A"
                                                                   :X-Base "1"}}
                                                  :child {:extends "base"
                                                          :headers {:authorization "Bearer B"}}})]
                      (assert.are.same {:authorization "Bearer B" :X-Base "1"}
                                       p.headers)))))
            (it "lets false in a profile override true in the config"
                (fn []
                  (let [d (cli.display-options {:verbose false :no-color false}
                                               {} {:verbose true :no-color true}
                                               true)]
                    (assert.is_false d.verbose)
                    (assert.is_false d.no-color))))
            (it "rejects circular and missing extends"
                (fn []
                  (assert.has.error #(cli.resolve-profile "a"
                                                          {:a {:extends "b"}
                                                           :b {:extends "a"}})
                                    "Circular extends: a")
                  (assert.has.error #(cli.resolve-profile "a"
                                                          {:a {:extends "z"}})
                                    "Profile not found: z")))
            (it "maps every tls key, and --ssl. flags override them"
                (fn []
                  (assert.are.same {:certificate "c.pem"
                                    :key "k.pem"
                                    :verify "none"
                                    :cafile "ca.pem"}
                                   (cli.tls->ssl {:cert "c.pem"
                                                  :key "k.pem"
                                                  :insecure true
                                                  :ca_cert "ca.pem"}))
                  (assert.is_nil (cli.tls->ssl {}))
                  (assert.are.same {:certificate "c.pem" :verify "peer"}
                                   (cli.merge-ssl {:tls {:cert "c.pem"
                                                         :insecure true}}
                                                  {:verify "peer"}))))
            (it "reads the config file, failing on corrupt JSON"
                (fn []
                  (let [path (cli.config-path)]
                    ;; never touch a real config
                    (assert.is_truthy (path:find "/build/test-home/" 1 true))
                    (os.execute (.. "mkdir -p '" (path:match "^(.*)/") "'"))
                    (assert.are.same {} (cli.load-config))
                    (with-open [f (io.open path :w)]
                      (f:write "{\"profiles\": {\"x\": {}}}"))
                    (assert.are.same {:profiles {:x {}}} (cli.load-config))
                    (with-open [f (io.open path :w)]
                      (f:write "{nope"))
                    (let [(ok err) (pcall cli.load-config)]
                      (os.remove path)
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find
                                           "corrupt config" 1 true))))))
            (it "serves a fetched schema from the cache until it expires"
                (fn []
                  (let [url (.. "https://cache.test/" (os.time) (math.random)
                                ".json")
                        calls []
                        opts {:transport (fn [req]
                                           (table.insert calls req)
                                           {:status 200
                                            :headers {}
                                            :raw "{\"openapi\": \"3.0.0\"}"})}]
                    (assert.are.same {:openapi "3.0.0"}
                                     (cli.load-schema-cached url opts))
                    (assert.are.same {:openapi "3.0.0"}
                                     (cli.load-schema-cached url opts))
                    (assert.are.equal 1 (length calls))
                    (cli.load-schema-cached url
                                            (doto (collect [k v (pairs opts)]
                                                    k
                                                    v)
                                              (tset :reload true)))
                    (assert.are.equal 2 (length calls)))))
            (it "colours output only on a terminal, unless NO_COLOR is set"
                (fn []
                  (assert.is_true (cli.colors-wanted? {} #true))
                  (assert.is_false (cli.colors-wanted? {} #false))
                  (assert.is_false (cli.colors-wanted? {:NO_COLOR "1"} #true))
                  ;; an empty NO_COLOR doesn't count
                  (assert.is_true (cli.colors-wanted? {:NO_COLOR ""} #true))
                  (assert.is_true (. (cli.display-options nil {} {} false)
                                     :no-color))
                  (assert.is_falsy (. (cli.display-options nil {} {} true)
                                      :no-color))
                  (assert.is_true (. (cli.display-options nil {:no-color true}
                                                          {} true)
                                     :no-color))))
            (it "marks the credentials it adds after a 401 as sensitive"
                (fn []
                  (let [seen []
                        responses [{:status 401 :headers {} :raw ""}
                                   {:status 200
                                    :headers {}
                                    :raw "{\"openapi\":\"3.0.0\"}"}]]
                    (cli.fetch-schema "https://h/s.json"
                                      {:transport (fn [req]
                                                    (table.insert seen req)
                                                    (. responses (length seen)))
                                       :auth-headers #{:x-client "k"}})
                    (assert.are.same [:x-client] (. seen 2 :sensitive-headers)))))
            (it "keeps credentials out of schema fetch errors"
                (fn []
                  (each [_ resp (ipairs [{:status 404 :headers {} :raw ""}
                                         {:status 200
                                          :headers {}
                                          :raw "<html>"}])]
                    (let [(ok err) (pcall cli.fetch-schema
                                          "https://u:pw@h/s.json?api_key=SECRET"
                                          {:transport #resp})]
                      (assert.is_false ok)
                      (assert.is_nil (: (tostring err) :find "SECRET" 1 true))
                      (assert.is_nil (: (tostring err) :find "pw" 1 true))))))
            (it "rejects a fetched page that is not a schema"
                (fn []
                  (let [(ok err) (pcall cli.fetch-schema "https://h/"
                                        {:transport (fn []
                                                      {:status 200
                                                       :headers {}
                                                       :raw "<html>hi</html>"})})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "'https://h/' is not an OpenAPI document"
                                         1 true)))))
            (it "prints curl commands and logs requests per the options"
                (fn []
                  (let [(_ out) (capture #(let [opts (cli.client-options nil
                                                                         nil
                                                                         {:curl true}
                                                                         {})]
                                            (opts.http-fn {:method "GET"
                                                           :url "https://h/x"})))]
                    (assert.are.equal "curl -X GET 'https://h/x'" out))
                  (let [(_ _ err) (capture #(let [opts (cli.client-options nil
                                                                           nil
                                                                           {:verbose true}
                                                                           {}
                                                                           (fn []
                                                                             {:status 200
                                                                              :headers {}}))]
                                              (opts.http-fn {:method "GET"
                                                             :url "https://h/x"})))]
                    (assert.are.equal "> GET https://h/x\n" err))))))

(fn bash-complete [shell line candidates]
  "COMPREPLY of the bash completion script for line, when ezu __complete
answers candidates; one reply per line, each followed by |."
  (let [(_ script) (capture cli.completion-bash)
        script-file (os.tmpname)
        sh-quote #(.. "'" (pick-values 1 ($:gsub "'" "'\\''")) "'")]
    (with-open [f (io.open script-file :w)]
      (f:write script "\n")
      (f:write (.. "ezu() { printf '%s\\n' "
                   (table.concat (icollect [_ c (ipairs candidates)]
                                   (sh-quote c))
                                 " ") "; }\n"))
      (f:write (.. "COMP_LINE=" (sh-quote line) "; COMP_POINT=${#COMP_LINE}\n"))
      (f:write "_ezu_complete\nprintf '%s|\\n' \"${COMPREPLY[@]}\"\n"))
    (let [p (io.popen (.. "cd /tmp && " shell " " script-file))
          out (p:read :*a)]
      (p:close)
      (os.remove script-file)
      out)))

(describe "repeated headers"
          (fn []
            (it "join cookies with ; and other headers with ,"
                (fn []
                  (let [p (cli.parse-args ["op"
                                           "s"
                                           "--h.Cookie=a=b"
                                           "--h.cookie=c=d"
                                           "--h.X-T=1"
                                           "--h.x-t=2"])]
                    (assert.are.equal "a=b; c=d" p.headers.Cookie)
                    (assert.are.equal "1, 2" (. p.headers :X-T)))))))

(describe "bash completion script"
          (fn []
            (it "treats candidates from the spec as data, and inserts them quoted"
                (fn []
                  (let [marker (os.tmpname)]
                    (os.remove marker)
                    (each [_ shell (ipairs ["bash" "/bin/bash"])]
                      ;; candidates as a malicious spec could make them
                      (let [out (bash-complete shell "ezu op x y --q.s="
                                               [(.. "--q.s=$(touch " marker ")")
                                                "--q.s=*"
                                                "--q.s=in progress"
                                                "--q.s=ok"])]
                        (let [ran (io.open marker)]
                          (when ran (ran:close) (os.remove marker))
                          (assert.is_nil ran))
                        ;; what readline puts after the =: quoted, a space
                        ;; after each complete word
                        (assert.are.equal (.. "\\$\\(touch\\ " marker
                                              "\\) |\n\\* |\nin\\ progress |\nok |\n")
                                          out))))))
            (it "replaces only what follows the last = or : of the word"
                (fn []
                  (each [_ shell (ipairs ["bash" "/bin/bash"])]
                    (assert.are.equal "fra-1 |\n"
                                      (bash-complete shell
                                                     "ezu op x y --q.zone=de:f"
                                                     ["--q.zone=de:fra-1"
                                                      "--q.zone=eu"]))
                    (assert.are.equal "v1 |\n"
                                      (bash-complete shell
                                                     "ezu op x y --q.zone=k="
                                                     ["--q.zone=k=v1"]))
                    (assert.are.equal "//x.example/a |\n"
                                      (bash-complete shell
                                                     "ezu op x y --q.u=https:"
                                                     ["--q.u=https://x.example/a"])))))
            (it "offers nothing once only the value is left to type"
                (fn []
                  ;; printf prints one empty reply line when there are none
                  (assert.are.equal "|\n"
                                    (bash-complete "bash" "ezu op x --output="
                                                   ["--output="]))))
            (it "adds no space after a name waiting for its value"
                (fn []
                  (assert.are.equal "--q.status=|\n"
                                    (bash-complete "bash" "ezu op x y --q.st"
                                                   ["--q.status=" "--q.sort="]))))))

(describe "zsh completion script"
          (fn []
            (it "passes the words of the command being completed"
                (fn []
                  (when (os.execute "command -v zsh >/dev/null 2>&1")
                    (let [(_ script) (capture cli.completion-zsh)
                          script-file (os.tmpname)]
                      (with-open [f (io.open script-file :w)]
                        (f:write "compdef() { :; }\n")
                        (f:write script "\n")
                        ;; what zsh gives a completion function for
                        ;; `true && ezu op be<TAB>`
                        (f:write "compadd() { :; }\n")
                        (f:write "BUFFER='true && ezu op be'; CURSOR=${#BUFFER}\n")
                        (f:write "words=(ezu op be); CURRENT=3; PREFIX=be\n")
                        (f:write (.. "ezu() { print -r -- \"line=$2\" > "
                                     script-file ".out; }\n"))
                        (f:write "_ezu\n"))
                      (os.execute (.. "zsh " script-file))
                      (let [out (with-open [f (io.open (.. script-file ".out"))]
                                  (f:read :*a))]
                        (os.remove script-file)
                        (os.remove (.. script-file ".out"))
                        (assert.are.equal "line=ezu op be\n" out))))))))

(describe "completion backend"
          (fn []
            (it "skips variable assignments before the program name"
                (fn []
                  (let [(_ out) (capture #(cli.run-complete ["__complete"
                                                             "FOO=1 BAR=x ezu pro"]))]
                    (assert.are.equal "profile" out))))))

(describe "import-restish discoverability"
          (fn []
            (it "completes the profile subcommand"
                (fn []
                  (assert.are.same ["import-restish"] (complete "profile im"))))))

(describe "cli.select-path"
          (fn []
            (let [data {:items [{:id 1 :name "a" :tags ["x"]}
                                {:id 2 :name "b" :tags ["y" "z"]}]
                        :meta {:count 2 :page {:next "n"}}}]
              (it "follows fields"
                  (fn []
                    (assert.are.equal "n"
                                      (cli.select-path data ".meta.page.next"))))
              (it "indexes arrays 0-based"
                  (fn []
                    (assert.are.equal "b"
                                      (cli.select-path data ".items[1].name"))))
              (it "iterates arrays and continues the path on each element"
                  (fn []
                    (assert.are.same [1 2] (cli.select-path data ".items[].id"))
                    (assert.are.same [["x"] ["y" "z"]]
                                     (cli.select-path data ".items[].tags"))))
              (it "picks fields from an object or from each element"
                  (fn []
                    (assert.are.same {:count 2}
                                     (cli.select-path data ".meta.{count}"))
                    (assert.are.same [{:id 1 :name "a"} {:id 2 :name "b"}]
                                     (cli.select-path data
                                                      ".items[].{id, name}"))
                    (assert.are.same [{:id 1} {:id 2}]
                                     (cli.select-path data ".items.{id}"))))
              (it "returns nil for missing paths"
                  (fn []
                    (assert.is_nil (cli.select-path data ".nope.deeper"))
                    (assert.is_nil (cli.select-path data ".items[9].name"))))
              (it "returns the data for an empty path"
                  (fn [] (assert.are.same data (cli.select-path data ""))))
              (it "continues the path after picking fields"
                  (fn []
                    (assert.are.equal 2
                                      (cli.select-path data
                                                       ".meta.{count}.count"))
                    (assert.are.same ["x" "y"]
                                     (cli.select-path data
                                                      ".items.{tags}.tags[0]"))))
              (it "returns nil where the path does not fit the data"
                  (fn []
                    (assert.is_nil (cli.select-path data ".meta.{count"))
                    (assert.is_nil (cli.select-path data ".meta.count[]"))
                    (assert.is_nil (cli.select-path data ".meta.count[0]"))
                    (assert.is_nil (cli.select-path data ".meta.count.x"))
                    (assert.is_nil (cli.select-path data ".meta.count.{a}"))
                    (assert.is_nil (cli.select-path false "{a}[0]"))))
              (it "keeps an empty array an array when picking fields"
                  (fn []
                    (let [json (require :ezu.json)]
                      (assert.is_true (json.array? (cli.select-path (json.array [])
                                                                    "{a}")))
                      (assert.is_true (json.array? (cli.select-path (json.array [])
                                                                    "[].a"))))))
              (it "picks fields only from the objects of a mixed array"
                  (fn []
                    (assert.are.same [{:a 1}]
                                     (cli.select-path [{:a 1 :b 2} 3 "x"] "{a}")))))))

(describe "cli.select-path filters"
          (fn []
            (let [data {:items [{:id 1
                                 :name "a"
                                 :state "running"
                                 :size 10
                                 :tags {:env "prod"}}
                                {:id 2 :name "b]c" :state "stopped" :size 20}
                                {:id 3
                                 :name "d"
                                 :state "running"
                                 :size 30
                                 :tags {:env "dev"}}]}]
              (it "keeps the elements that match, bare or JSON values"
                  (fn []
                    (assert.are.same [1 3]
                                     (cli.select-path data
                                                      ".items[?state==running].id"))
                    (assert.are.same [1 3]
                                     (cli.select-path data
                                                      ".items[?state==\"running\"].id"))
                    (assert.are.same [2]
                                     (cli.select-path data
                                                      ".items[?state!=running].id"))))
              (it "compares numbers"
                  (fn []
                    (assert.are.same ["b]c" "d"]
                                     (cli.select-path data
                                                      ".items[?size>15].name"))
                    (assert.are.same [1]
                                     (cli.select-path data
                                                      ".items[?size<=10].id"))
                    (assert.are.same [2 3]
                                     (cli.select-path data
                                                      ".items[?size>=20].id"))
                    (assert.are.same [1]
                                     (cli.select-path data
                                                      ".items[?size<20.5][?size<11].id"))))
              (it "follows paths in the condition"
                  (fn []
                    (assert.are.same [1]
                                     (cli.select-path data
                                                      ".items[?tags.env==prod].id"))
                    (assert.are.same [3]
                                     (cli.select-path data
                                                      ".items[?.tags.env==\"dev\"].id"))))
              (it "tests presence without an operator"
                  (fn []
                    (assert.are.same [1 3]
                                     (cli.select-path data ".items[?tags].id"))))
              (it "treats missing fields as null"
                  (fn []
                    (let [json (require :ezu.json)]
                      (assert.are.same [2]
                                       (cli.select-path data
                                                        ".items[?tags==null].id"))
                      (assert.are.same [9]
                                       (cli.select-path {:a [{:id 9
                                                              :x json.null}
                                                             {:id 8 :x 1}]}
                                                        ".a[?x==null].id"))
                      (assert.are.same [8]
                                       (cli.select-path {:a [{:id 9
                                                              :x json.null}
                                                             {:id 8 :x 1}]}
                                                        ".a[?x].id")))))
              (it "reads brackets inside quoted values"
                  (fn []
                    (assert.are.same [2]
                                     (cli.select-path data
                                                      ".items[?name==\"b]c\"].id"))))
              (it "gives whole elements, and an empty array when none match"
                  (fn []
                    (assert.are.same [{:id 2
                                       :name "b]c"
                                       :state "stopped"
                                       :size 20}]
                                     (cli.select-path data
                                                      ".items[?state==stopped]"))
                    (let [json (require :ezu.json)
                          none (cli.select-path data ".items[?size>99]")]
                      (assert.is_true (json.array? none))
                      (assert.are.same [] none))))
              (it "never matches values of another type"
                  (fn []
                    (assert.are.same []
                                     (cli.select-path data ".items[?name>1].id"))))
              (it "is nil on things that aren't arrays"
                  (fn []
                    (assert.is_nil (cli.select-path data ".items[0][?id==1]"))))
              (it "checks filters without data"
                  (fn []
                    (cli.check-select ".a[?name==\"[?x\"].b[?c>1]")
                    (assert.is_false (pcall cli.check-select
                                            ".a[?x==1].b[?c=1]"))))
              (it "rejects malformed filters"
                  (fn []
                    (each [_ path (ipairs [".items[?n<>1]"
                                           ".items[?n!==1]"
                                           ".items[?x==[1]]"
                                           ".items[?n===a]"
                                           ".items[?n==a]]"
                                           ".items[?n=={}]"
                                           ".items[?state=running]"
                                           ".items[?]"
                                           ".items[?state==\"x]"
                                           ".items[?size>]"])]
                      (let [(ok err) (pcall cli.select-path data path)]
                        (assert.is_false ok)
                        (assert.is_truthy (: (tostring err) :find
                                             "invalid filter" 1 true)))))))))

(describe "cli.format-output tables"
          (fn []
            (let [resp {:status 200
                        :headers {}
                        :body [{:id 1 :name "a" :tags {:k "v"}}
                               {:id 22 :name "b,\"c\""}]}]
              (it "aligns columns, sorted by name, with a header"
                  (fn []
                    (assert.are.equal (.. "id  name   tags\n"
                                          "1   a      {\"k\":\"v\"}\n"
                                          "22  b,\"c\"")
                                      (cli.format-output resp :table false))))
              (it "orders columns as the selection picks them"
                  (fn []
                    (assert.are.equal "name   id\na      1\nb,\"c\"  22"
                                      (cli.format-output resp :table false
                                                         "[].{name,id}"))))
              (it "aligns wide characters by their display width"
                  (fn []
                    (assert.are.equal "name  id\n日本  1\nab    2"
                                      (cli.format-output {:status 200
                                                          :headers {}
                                                          :body [{:name "日本"
                                                                  :id 1}
                                                                 {:name "ab"
                                                                  :id 2}]}
                                                         :table false
                                                         "[].{name,id}"))))
              (it "writes CSV with quoting"
                  (fn []
                    (assert.are.equal (.. "id,name,tags\n"
                                          "1,a,\"{\"\"k\"\":\"\"v\"\"}\"\n"
                                          "22,\"b,\"\"c\"\"\",")
                                      (cli.format-output resp :csv false))))
              (it "writes TSV with escapes"
                  (fn []
                    (assert.are.equal "a\tb\na\\tb\tx\\ny\\\\"
                                      (cli.format-output {:status 200
                                                          :headers {}
                                                          :body [{:a "a\tb"
                                                                  :b "x\ny\\"}]}
                                                         :tsv false "[].{a,b}"))))
              (it "makes an object one row and a list of values one per line"
                  (fn []
                    (assert.are.equal "id\n7"
                                      (cli.format-output {:status 200
                                                          :headers {}
                                                          :body {:id 7}}
                                                         :csv false))
                    (assert.are.equal "a\nb c"
                                      (cli.format-output {:status 200
                                                          :headers {}
                                                          :body ["a" "b c"]}
                                                         :table false))))
              (it "escapes control characters in tables"
                  (fn []
                    (assert.is_nil (: (cli.format-output {:status 200
                                                          :headers {}
                                                          :body [{:a "\27[2J"}]}
                                                         :table false)
                                      :find "\27" 1 true))))
              (it "writes arrays inside arrays one per line, as JSON"
                  (fn []
                    (assert.are.equal "[1,2]\n[3]"
                                      (cli.format-output {:status 200
                                                          :headers {}
                                                          :body [[1 2] [3]]}
                                                         :table false))
                    (assert.are.equal "a\n1"
                                      (cli.format-output {:status 200
                                                          :headers {}
                                                          :body [{:a 1} [5]]}
                                                         :csv false))))
              (it "prints nothing for rows without columns"
                  (fn []
                    (let [json (require :ezu.json)]
                      (assert.is_nil (cli.format-output {:status 200
                                                         :headers {}
                                                         :body [{} {}]}
                                                        :table false))
                      (assert.is_nil (cli.format-output {:status 200
                                                         :headers {}
                                                         :body json.null}
                                                        :csv false)))))
              (it "prints nothing for an empty array, or the selected header"
                  (fn []
                    (let [json (require :ezu.json)
                          empty {:status 200
                                 :headers {}
                                 :body (json.array [])
                                 :raw "[]"}]
                      (assert.is_nil (cli.format-output empty :table false))
                      (assert.are.equal "a,b"
                                        (cli.format-output empty :csv false
                                                           "[].{a,b}"))
                      (assert.is_nil (cli.format-output {:status 200
                                                         :headers {}
                                                         :body {:x (json.array [])}
                                                         :raw "{}"}
                                                        :raw false ".x")))))
              (it "escapes control characters in csv and tsv on a terminal only"
                  (fn []
                    (let [r {:status 200 :headers {} :body [{:a "x\27[2J"}]}]
                      (each [_ fmt (ipairs [:csv :tsv])]
                        (assert.is_nil (: (cli.format-output r fmt false nil
                                                             true)
                                          :find "\27" 1 true))
                        (assert.is_truthy (: (cli.format-output r fmt false nil
                                                                false)
                                             :find "\27" 1 true))))))
              (it "raw prints a list of values one per line"
                  (fn []
                    (assert.are.equal "a\n1\ntrue"
                                      (cli.format-output {:status 200
                                                          :headers {}
                                                          :body {:x ["a"
                                                                     1
                                                                     true]}
                                                          :raw "{}"}
                                                         :raw false ".x")))))))

(describe "cli.select-path from the end and in depth"
          (fn []
            (let [data {:items [{:id 1 :name "a" :tags ["x"]}
                                {:id 2 :name "b" :tags ["y" "z"]}]
                        :meta {:count 2 :page {:next "n"}}}]
              (it "counts negative indexes from the end"
                  (fn []
                    (assert.are.equal "b"
                                      (cli.select-path data ".items[-1].name"))
                    (assert.are.equal 1 (cli.select-path data ".items[-2].id"))
                    (assert.are.equal "z"
                                      (cli.select-path data
                                                       ".items[1].tags[-1]"))
                    (assert.is_nil (cli.select-path data ".items[-3]"))))
              (it "finds a field at any depth with .."
                  (fn []
                    (assert.are.same ["a" "b"] (cli.select-path data "..name"))
                    (assert.are.same [1 2] (cli.select-path data ".items..id"))
                    (assert.are.same ["n"] (cli.select-path data "..page.next"))
                    (assert.are.same [["y" "z"]]
                                     (cli.select-path data "..items[1].tags"))))
              (it "finds fields inside the ones it found"
                  (fn []
                    (assert.are.same [{:a {:a 1}} {:a 1} 1]
                                     (cli.select-path {:a {:a {:a 1}}} "..a"))))
              (it "needs a field name after .."
                  (fn []
                    (each [_ path (ipairs [".."
                                           "..[0]"
                                           "..{id}"
                                           "...id"
                                           ".a.."])]
                      (let [(ok err) (pcall cli.check-select path)]
                        (assert.is_false ok)
                        (assert.is_truthy (: (tostring err) :find
                                             "must be followed by a field name"
                                             1 true))))
                    (cli.check-select "..id[?name==\"a..b\"].x")))
              (it "refuses .. in a filter's field"
                  (fn []
                    (let [(ok err) (pcall cli.check-select "[?tags..env]")]
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find
                                           "invalid filter" 1 true)))))
              (it "finds nothing as an empty array"
                  (fn []
                    (let [json (require :ezu.json)
                          none (cli.select-path data "..nope")]
                      (assert.is_true (json.array? none))
                      (assert.are.same [] none)))))))
