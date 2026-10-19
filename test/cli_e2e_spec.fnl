;; ABOUTME: End-to-end specs for the ezu commands, run in-process through
;; ABOUTME: cli.run with a fake HTTP transport and an in-memory config.
(local cli (require :ezu.cli))

(fn respond [status body ?headers]
  (let [json (require :lunajson)
        raw (if (= nil body) "" (json.encode body))]
    {:status status
     :headers (or ?headers {:content-type "application/json"})
     :body body
     :raw raw}))

(fn routes-transport [routes]
  "Fake transport answering by \"METHOD URL\" (URL with query); records requests."
  (let [requests []]
    (values (fn [req]
              (let [util (require :ezu.util)
                    url (util.append-query req.url (or req.query {}))
                    route (or (. routes (.. req.method " " url)) (. routes url))]
                (table.insert requests req)
                (let [resp (if (= (type route) :function) (route req)
                               route route
                               (respond 404 {:error "no route"}))
                      ;; the transport's streaming: req.stream takes the
                      ;; body piece by piece, or leaves it
                      consumer (when req.stream
                                 (req.stream resp.status resp.headers))]
                  (if consumer
                      (do
                        ;; as the transport does: what the consumer raises
                        ;; is never retried
                        (each [_ piece (ipairs (doto (icollect [_ p (ipairs (or resp.pieces
                                                                                [resp.raw]))]
                                                       p)
                                                 (table.insert false)))]
                          (let [(ok err) (pcall consumer (or piece nil))]
                            (when (not ok)
                              (when (= (type err) :table)
                                (set err.permanent true))
                              (error err 0))))
                        {:status resp.status
                         :headers resp.headers
                         :raw ""
                         :streamed true})
                      resp)))) requests)))

(fn respond-text [status content-type pieces]
  "A response whose body is the text of pieces, decoded as the transport
does, which a streaming transport hands over one by one."
  (let [http (require :ezu.http)]
    (doto (http.decode-response status {:content-type content-type}
                                (table.concat pieces))
      (tset :pieces pieces))))

(local config {:profiles {:p {:schema "test/fixtures/cli-api.json"
                              :headers {:x-org "o1"}
                              :auth {:name "bearer" :params {:token "t0k"}}}
                          :broken-auth {:schema "test/fixtures/cli-api.json"
                                        :auth {:name "external-tool"
                                               :params {:commandline "exit 1"
                                                        :output "bearer-token"}}}
                          :yaml {:schema "test/fixtures/cli-api.json"
                                 :output "yaml"
                                 :no-color true}
                          :counted {:schema "test/fixtures/cli-api.json"
                                    :auth {:name "external-tool"
                                           :params {:commandline "echo run >> build/test-home/auth-runs; echo tok"
                                                    :output "bearer-token"}}}}
               :arazzo {:flows {:file "test/fixtures/cli-flow.arazzo.json"
                                :profile "yaml"}}})

(var current-config config)

;; a stdout whose reader went away: writes fail as on a closed pipe
(var stdout-closed false)

(fn with-config [cfg f]
  "Runs f with cfg as the CLI config."
  (set current-config cfg)
  (let [(ok result) (pcall f)]
    (set current-config config)
    (assert ok result)
    result))

(fn ezu-run [args ?routes ?program ?env]
  "Run the CLI in-process, as ?program (default ezu), with ?env added to its
environment; returns {:code :out :err :requests}."
  (let [(transport requests) (routes-transport (or ?routes {}))
        out []
        err []
        real-print _G.print
        real-stderr io.stderr
        real-stdout io.stdout
        written []]
    (set _G.print (fn [...]
                    (table.insert out
                                  (table.concat (icollect [_ v (ipairs [...])]
                                                  (tostring v))
                                                "\t"))))
    (set io.stderr {:write (fn [_ s] (table.insert err s))})
    (set io.stdout {:write (fn [self s]
                             (if stdout-closed
                                 (values nil "Broken pipe" 32)
                                 (do
                                   (table.insert written s)
                                   self)))
                    :flush #true})
    (let [(ok code) (pcall cli.run args
                           (doto {: transport
                                  :config current-config
                                  :program (or ?program "/usr/local/bin/ezu")}
                             (#(each [k v (pairs (or ?env {}))]
                                 (tset $ k v)))))]
      (set _G.print real-print)
      (set io.stderr real-stderr)
      (set io.stdout real-stdout)
      ;; as print's lines are joined: no newline after the last
      (when (next written)
        (table.insert out
                      (pick-values 1 (: (table.concat written) :gsub "\n$" ""))))
      (assert ok code)
      {: code :out (table.concat out "\n") :err (table.concat err) : requests})))

(describe "ezu op"
          (fn []
            (it "sends the request with profile headers and auth, exit 0"
                (fn []
                  (let [r (ezu-run ["op" "p" "get-pet" "7" "--no-color"]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {:name "Rex"})})]
                    (assert.are.equal 0 r.code)
                    (assert.is_truthy (r.out:find "\"name\": \"Rex\"" 1 true))
                    (assert.are.equal "Bearer t0k"
                                      (. r.requests 1 :headers :authorization))
                    (assert.are.equal "o1" (. r.requests 1 :headers :x-org)))))
            (it "maps HTTP errors to exit codes 4 and 5"
                (fn []
                  (assert.are.equal 4
                                    (. (ezu-run ["op" "p" "get-pet" "1"]) :code))
                  (assert.are.equal 5
                                    (. (ezu-run ["op"
                                                 "p"
                                                 "get-pet"
                                                 "1"
                                                 "--retry=0"]
                                                {"GET https://api.test/pets/1" (respond 503
                                                                                        {})})
                                       :code))
                  (assert.are.equal 0
                                    (. (ezu-run ["op"
                                                 "p"
                                                 "get-pet"
                                                 "1"
                                                 "--ignore-status"
                                                 "--retry=0"]
                                                {"GET https://api.test/pets/1" (respond 503
                                                                                        {})})
                                       :code))))
            (it "blocks invalid bodies before sending"
                (fn []
                  (let [r (ezu-run ["op" "p" "add-pet" "--b.size=1"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "body.name: required" 1 true))
                    (assert.are.equal 0 (length r.requests)))))
            (it "sends anyway with --no-validate"
                (fn []
                  (let [r (ezu-run ["op"
                                    "p"
                                    "add-pet"
                                    "--b.size=1"
                                    "--no-validate"]
                                   {"POST https://api.test/pets" (respond 201
                                                                          {})})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal 1 (length r.requests)))))
            (it "counts the auth header toward required headers"
                (fn []
                  (assert.are.equal 0
                                    (. (ezu-run ["op" "p" "get-secure"]
                                                {"GET https://api.test/secure" (respond 200
                                                                                        {})})
                                       :code))))
            (it "does not authenticate for --help, --list or --servers"
                (fn []
                  (assert.are.equal 0
                                    (. (ezu-run ["op" "broken-auth" "--list"])
                                       :code))
                  (assert.are.equal 0
                                    (. (ezu-run ["op"
                                                 "broken-auth"
                                                 "get-pet"
                                                 "--help"])
                                       :code))
                  (assert.are.equal 0
                                    (. (ezu-run ["op"
                                                 "broken-auth"
                                                 "--servers"])
                                       :code))))
            (it "reports an auth failure when a request needs it"
                (fn []
                  (let [r (ezu-run ["op" "broken-auth" "get-pet" "1"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "authentication failed" 1
                                                  true)))))
            (it "prints the request for --dry-run without sending"
                (fn []
                  (let [r (ezu-run ["op"
                                    "p"
                                    "list-pets"
                                    "--q.status=sold"
                                    "--dry-run"])]
                    (assert.are.equal 0 r.code)
                    (assert.is_truthy (r.out:find "GET https://api.test/pets?status=sold"
                                                  1 true))
                    (assert.are.equal 0 (length r.requests)))))
            (it "escapes control characters of the spec's text"
                (fn []
                  (let [spec (.. (os.tmpname) ".json")]
                    (with-open [f (io.open spec :w)]
                      (f:write "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://h\",\"description\":\"s\\u001b[2J\"}],\"paths\":{\"/x\":{\"get\":{\"operationId\":\"getX\",\"summary\":\"list \\u001b]52;c;cHduZWQ=\\u0007\",\"description\":\"d\\u001b[31m\",\"responses\":{}}}}}"))
                    (let [outs (icollect [_ args (ipairs [["op" spec "--list"]
                                                          ["op"
                                                           spec
                                                           "get-x"
                                                           "--help"]
                                                          ["op"
                                                           spec
                                                           "--servers"]])]
                                 (. (ezu-run args) :out))]
                      (os.remove spec)
                      (each [_ out (ipairs outs)]
                        (assert.is_nil (out:find "\27" 1 true))
                        (assert.is_truthy (out:find "\\x1B" 1 true)))))))
            (it "escapes control characters in requests, headers and error bodies"
                (fn []
                  (let [spec (.. (os.tmpname) ".json")]
                    (with-open [f (io.open spec :w)]
                      (f:write "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://h/a\\u001b]0;T\\u0007\"}],\"paths\":{\"/x\":{\"get\":{\"operationId\":\"getX\",\"responses\":{}}}}}"))
                    (let [outs (icollect [_ extra (ipairs [["--dry-run"]
                                                           ["--curl"]])]
                                 (let [r (ezu-run (doto ["op" spec "get-x"]
                                                    (table.insert (. extra 1))))]
                                   (.. r.out r.err)))
                          url "https://h/a\27]0;T\7/x"
                          routes {url {:status 400
                                       :headers {:content-type "text/plain"
                                                 :x-evil "a\27[2Jb"}
                                       :body "bad \27[31m"
                                       :raw "bad \27[31m"}}
                          v (ezu-run ["op" spec "get-x" "-v"] routes)]
                      (os.remove spec)
                      (table.insert outs (.. v.out v.err))
                      (each [_ out (ipairs outs)]
                        (assert.is_nil (out:find "\27" 1 true) out))))))
            (it "escapes control characters in errors and warnings"
                (fn []
                  (let [spec (.. (os.tmpname) ".json")]
                    (with-open [f (io.open spec :w)]
                      (f:write "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://h\"}],\"paths\":{\"/x\":{\"get\":{\"operationId\":\"getX\",\"parameters\":[{\"name\":\"q\\u001b]0;P\\u0007\",\"in\":\"query\"}],\"responses\":{\"200\":{\"$ref\":\"#/nope\\u001b[31m\"}}}}}}"))
                    (let [r (ezu-run ["op" spec "--list"])]
                      (assert.are.equal 1 r.code)
                      (assert.is_nil (r.err:find "\27" 1 true))
                      (assert.is_truthy (r.err:find "\\x1B" 1 true)))
                    (with-open [f (io.open spec :w)]
                      (f:write "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://h\"}],\"paths\":{\"/x\":{\"get\":{\"operationId\":\"getX\",\"parameters\":[{\"name\":\"q\\u001b]0;P\\u0007\",\"in\":\"query\"}],\"responses\":{}}}}}"))
                    (let [r (ezu-run ["op" spec "get-x" "--q.zz=1" "--dry-run"])]
                      (os.remove spec)
                      (assert.is_truthy (r.err:find "warning" 1 true))
                      (assert.is_nil (r.err:find "\27" 1 true))))))
            (it "sends --q. values of JSON query parameters as given"
                (fn []
                  (let [spec (.. (os.tmpname) ".json")]
                    (with-open [f (io.open spec :w)]
                      (f:write "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://h\"}],\"paths\":{\"/s\":{\"get\":{\"operationId\":\"search\",\"parameters\":[{\"name\":\"filter\",\"in\":\"query\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\"}}}}],\"responses\":{}}}}}"))
                    (let [r (ezu-run ["op"
                                      spec
                                      "search"
                                      "--q.filter={\"a\":1}"
                                      "--dry-run"])]
                      (os.remove spec)
                      (assert.is_truthy (r.out:find "GET https://h/s?filter=%7B%22a%22%3A1%7D"
                                                    1 true)
                                        r.out)))))
            (it "reads a query API key only when a request is sent"
                (fn []
                  (with-config {:profiles {:q {:schema "test/fixtures/cli-api.json"
                                               :auth {:name "api-key"
                                                      :params {:in "query"
                                                               :name "apikey"
                                                               :value "env:EZU_TEST_UNSET_KEY"}}}}}
                    #(do
                       (assert.are.equal 0
                                         (. (ezu-run ["op" "q" "--list"]) :code))
                       (assert.are.equal 0
                                         (. (ezu-run ["op"
                                                      "q"
                                                      "list-pets"
                                                      "--help"])
                                            :code))
                       (let [r (ezu-run ["op" "q" "list-pets" "--dry-run"])]
                         (assert.are.equal 0 r.code)
                         (assert.is_truthy (r.out:find "apikey=<redacted>" 1
                                                       true)
                                           r.out))
                       (let [r (ezu-run ["op" "q" "list-pets"])]
                         (assert.are.equal 1 r.code)
                         (assert.is_truthy (r.err:find "EZU_TEST_UNSET_KEY" 1
                                                       true)))))))
            (it "rejects body fields on top of an array body"
                (fn []
                  (let [r (ezu-run ["op"
                                    "p"
                                    "add-pet"
                                    "-d"
                                    "[1]"
                                    "--b.x=1"
                                    "--no-validate"
                                    "--dry-run"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "require --body to be a JSON object"
                                                  1 true)))))
            (it "rejects a document that is not an OpenAPI spec"
                (fn []
                  (let [path (.. (os.tmpname) ".json")
                        (transport) (routes-transport {"GET https://api.test/echo" {:status 200
                                                                                    :headers {}
                                                                                    :raw "{\"a\":1}"}})]
                    (with-open [f (io.open path :w)]
                      (f:write "{\"a\":1}"))
                    (let [r (ezu-run ["op" path "--list"])
                          real-stderr io.stderr
                          err []]
                      (os.remove path)
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find "is not an OpenAPI document"
                                                    1 true)
                                        r.err)
                      (set io.stderr {:write (fn [_ s] (table.insert err s))})
                      (let [code (cli.run ["op"
                                           "https://api.test/echo"
                                           "--list"]
                                          {: transport
                                           :config {}
                                           :schema-cache false})]
                        (set io.stderr real-stderr)
                        (assert.are.equal 1 code)
                        (assert.is_truthy (: (table.concat err) :find
                                             "is not an OpenAPI document" 1 true)))))))
            (it "explains a profile without a schema"
                (fn []
                  (let [r (with-config {:profiles {:noschema {:headers {:x-a "b"}}}}
                            #(ezu-run ["op" "noschema" "list-pets"]))]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "profile noschema has no schema"
                                                  1 true)
                                      r.err))))
            (it "validates bodies and uploads files whatever the media type's case"
                (fn []
                  (let [spec (.. (os.tmpname) ".json")
                        file (.. (os.tmpname) ".txt")]
                    (with-open [f (io.open file :w)]
                      (f:write "hello"))
                    (with-open [f (io.open spec :w)]
                      (f:write "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://h\"}],\"paths\":{\"/j\":{\"post\":{\"operationId\":\"create\",\"requestBody\":{\"content\":{\"Application/JSON\":{\"schema\":{\"type\":\"object\",\"required\":[\"name\"]}}}},\"responses\":{}}},\"/m\":{\"post\":{\"operationId\":\"upload\",\"requestBody\":{\"content\":{\"Multipart/Form-Data\":{\"schema\":{\"type\":\"object\"}}}},\"responses\":{}}}}}"))
                    (let [v (ezu-run ["op" spec "create" "--b.x=1" "--dry-run"])
                          m (ezu-run ["op"
                                      spec
                                      "upload"
                                      (.. "--b.file=@" file)
                                      "--dry-run"])]
                      (os.remove spec)
                      (os.remove file)
                      (assert.are.equal 1 v.code)
                      (assert.is_truthy (v.err:find "body.name: required" 1
                                                    true))
                      (assert.is_truthy (m.out:find "filename=" 1 true) m.out)))))
            (it "rejects a repeated JSON query parameter"
                (fn []
                  (let [spec (.. (os.tmpname) ".json")]
                    (with-open [f (io.open spec :w)]
                      (f:write "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://h\"}],\"paths\":{\"/s\":{\"get\":{\"operationId\":\"search\",\"parameters\":[{\"name\":\"filter\",\"in\":\"query\",\"content\":{\"application/json\":{\"schema\":{}}}}],\"responses\":{}}}}}"))
                    (let [r (ezu-run ["op"
                                      spec
                                      "search"
                                      "--q.filter={\"a\":1}"
                                      "--q.filter={\"b\":2}"
                                      "--dry-run"])]
                      (os.remove spec)
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find "filter takes one JSON value"
                                                    1 true)
                                        r.err)))))
            (it "counts query parameters the profile or a query key adds"
                (fn []
                  (let [spec (.. (os.tmpname) ".json")]
                    (with-open [f (io.open spec :w)]
                      (f:write "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://h\"}],\"paths\":{\"/items\":{\"get\":{\"operationId\":\"listItems\",\"parameters\":[{\"name\":\"appid\",\"in\":\"query\",\"required\":true}],\"responses\":{}}}}}"))
                    (let [cfg {:profiles {:q {:schema spec
                                              :auth {:name "api-key"
                                                     :params {:in "query"
                                                              :name "appid"
                                                              :value "K"}}}
                                          :pq {:schema spec
                                               :query {:appid "P"}}}}
                          rq (with-config cfg
                               #(ezu-run ["op" "q" "list-items" "--dry-run"]))
                          rpq (with-config cfg
                                #(ezu-run ["op" "pq" "list-items" "--dry-run"]))]
                      (os.remove spec)
                      (assert.are.equal 0 rq.code)
                      (assert.are.equal 0 rpq.code)
                      (assert.is_nil (rpq.err:find "warning" 1 true))))))
            (it "rejects a body for an operation that takes none"
                (fn []
                  (each [_ extra (ipairs ["-d={}" "--b.z=2"])]
                    (let [r (ezu-run ["op" "p" "get-pet" "7" extra "--dry-run"])]
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find "get-pet takes no request body"
                                                    1 true))))))
            (it "doesn't retry a request its signing tool failed to sign"
                (fn []
                  (let [count-file (os.tmpname)]
                    (let [r (with-config {:profiles {:sig {:schema "test/fixtures/cli-api.json"
                                                           :auth {:name "external-tool"
                                                                  :params {:commandline (.. "echo x >> "
                                                                                            count-file
                                                                                            "; exit 3")}}}}}
                              #(ezu-run ["op" "sig" "list-pets"]))
                          runs (with-open [f (io.open count-file)]
                                 (length (f:read :*a)))]
                      (os.remove count-file)
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find "external auth command failed"
                                                    1 true))
                      ;; "x\n" once
                      (assert.are.equal 2 runs)))))
            (it "does not run the signing tool for --dry-run"
                (fn []
                  (let [marker (os.tmpname)]
                    (os.remove marker)
                    (let [r (with-config {:profiles {:sign {:schema "test/fixtures/cli-api.json"
                                                            :auth {:name "external-tool"
                                                                   :params {:commandline (.. "touch "
                                                                                             marker
                                                                                             "; echo '{}'")}}}}}
                              #(ezu-run ["op" "sign" "list-pets" "--dry-run"]))
                          ran (io.open marker)]
                      (when ran
                        (ran:close)
                        (os.remove marker))
                      (assert.are.equal 0 r.code)
                      (assert.is_nil ran)))))
            (it "uses the profile's output format"
                (fn []
                  (let [r (ezu-run ["op" "yaml" "get-pet" "3"]
                                   {"GET https://api.test/pets/3" (respond 200
                                                                           {:name "Rex"})})]
                    (assert.are.equal "name: Rex" r.out))))
            (it "reports unknown operations"
                (fn []
                  (let [r (ezu-run ["op" "p" "nope"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "Unknown operation: nope" 1
                                                  true)))))
            (it "fetches a schema URL, authenticating only after a 401"
                (fn []
                  (let [schema-text (let [f (io.open "test/fixtures/cli-api.json")]
                                      (f:read :*a))
                        cfg-run (fn [args routes]
                                  (let [(transport requests) (routes-transport routes)
                                        real-print _G.print]
                                    (set _G.print (fn []))
                                    (let [code (cli.run args
                                                        {: transport
                                                         :config {:profiles {:remote {:schema "https://api.test/openapi.json"
                                                                                      :auth {:name "bearer"
                                                                                             :params {:token "t"}}}}}
                                                         :schema-cache false})]
                                      (set _G.print real-print)
                                      (values code requests))))
                        (code requests) (cfg-run ["op" "remote" "--list"]
                                                 {"GET https://api.test/openapi.json" (fn [req]
                                                                                        (if (. req.headers
                                                                                               :authorization)
                                                                                            {:status 200
                                                                                             :headers {}
                                                                                             :raw schema-text}
                                                                                            (respond 401
                                                                                                     {})))})]
                    (assert.are.equal 0 code)
                    (assert.are.equal 2 (length requests))
                    (assert.is_nil (. requests 1 :headers :authorization)))))
            (it "fetches the spec within --timeout"
                (fn []
                  (let [(transport requests) (routes-transport {"GET https://api.test/openapi.json" (respond 500
                                                                                                             {})})
                        real-stderr io.stderr]
                    (set io.stderr {:write (fn [])})
                    (cli.run ["op" "remote" "--list" "--timeout" "2"]
                             {: transport
                              :config {:profiles {:remote {:schema "https://api.test/openapi.json"}}}
                              :schema-cache false})
                    (set io.stderr real-stderr)
                    (assert.are.equal 2 (. requests 1 :timeout)))))
            (it "keeps profile headers from the documents a foreign spec refers to"
                (fn []
                  (let [spec "{\"openapi\":\"3.0.0\",\"info\":{},\"paths\":{\"/x\":{\"get\":{\"operationId\":\"getX\",\"parameters\":[{\"$ref\":\"part.json#/p\"}],\"responses\":{}}}}}"
                        (transport requests) (routes-transport {"GET https://specs.test/spec.json" {:status 200
                                                                                                    :headers {}
                                                                                                    :raw spec}
                                                                "GET https://specs.test/part.json" {:status 200
                                                                                                    :headers {}
                                                                                                    :raw "{\"p\":{\"name\":\"q\",\"in\":\"query\"}}"}})
                        code (cli.run ["op" "remote" "--list"]
                                      {: transport
                                       :config {:profiles {:remote {:schema "https://specs.test/spec.json"
                                                                    :base-url "https://api.test"
                                                                    :headers {:x-team "H"}}}}
                                       :schema-cache false})]
                    (assert.are.equal 0 code)
                    (assert.are.equal 2 (length requests))
                    (each [_ req (ipairs requests)]
                      (assert.is_nil (. req.headers :x-team))))))
            (it "never sends placeholder credentials for a dry run's spec"
                (fn []
                  (let [(transport requests) (routes-transport {"GET https://api.test/openapi.json" (respond 401
                                                                                                             {})})
                        real-stderr io.stderr]
                    (set io.stderr {:write (fn [])})
                    (cli.run ["op" "remote" "list-pets" "--dry-run"]
                             {: transport
                              :config {:profiles {:remote {:schema "https://api.test/openapi.json"
                                                           :auth {:name "bearer"
                                                                  :params {:token "t"}}}}}
                              :schema-cache false})
                    (set io.stderr real-stderr)
                    (each [_ req (ipairs requests)]
                      (assert.is_nil (. req.headers :authorization))))))
            (it "logs the fetches of a spec and its documents under -v"
                (fn []
                  (let [spec "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://specs.test\"}],\"paths\":{\"/x\":{\"get\":{\"operationId\":\"getX\",\"parameters\":[{\"$ref\":\"part.json#/p\"}],\"responses\":{}}}}}"
                        (transport) (routes-transport {"GET https://specs.test/spec.json" {:status 200
                                                                                           :headers {}
                                                                                           :raw spec}
                                                       "GET https://specs.test/part.json" {:status 200
                                                                                           :headers {}
                                                                                           :raw "{\"p\":{\"name\":\"q\",\"in\":\"query\"}}"}})
                        err []
                        real-stderr io.stderr]
                    (set io.stderr {:write (fn [_ s] (table.insert err s))})
                    (cli.run ["op"
                              "https://specs.test/spec.json"
                              "--list"
                              "-v"]
                             {: transport :config {} :schema-cache false})
                    (set io.stderr real-stderr)
                    (let [text (table.concat err)]
                      (assert.is_truthy (text:find "> GET https://specs.test/spec.json"
                                                   1 true))
                      (assert.is_truthy (text:find "> GET https://specs.test/part.json"
                                                   1 true))))))
            (it "fetches a spec with credentials when it was sent to a login page"
                (fn []
                  (let [schema-text (with-open [f (io.open "test/fixtures/cli-api.json")]
                                      (f:read :*a))
                        (transport requests) (routes-transport {"GET https://api.test/openapi.json" (fn [req]
                                                                                                      (if (. req.headers
                                                                                                             :authorization)
                                                                                                          {:status 200
                                                                                                           :headers {}
                                                                                                           :url "https://api.test/openapi.json"
                                                                                                           :raw schema-text}
                                                                                                          ;; an auth proxy: off to its login page
                                                                                                          {:status 200
                                                                                                           :headers {:content-type "text/html"}
                                                                                                           :url "https://login.test/auth?state=x"
                                                                                                           :raw "<html>sign in</html>"}))})
                        code (cli.run ["op" "remote" "--list"]
                                      {: transport
                                       :config {:profiles {:remote {:schema "https://api.test/openapi.json"
                                                                    :auth {:name "bearer"
                                                                           :params {:token "t"}}}}}
                                       :schema-cache false})]
                    (assert.are.equal 0 code)
                    (assert.are.equal 2 (length requests))
                    (assert.is_nil (. requests 1 :headers :authorization)))))
            (it "fetches a spec protected by a query API key after a 401"
                (fn []
                  (let [schema-text (with-open [f (io.open "test/fixtures/cli-api.json")]
                                      (f:read :*a))
                        (transport requests) (routes-transport {"GET https://api.test/openapi.json" (respond 401
                                                                                                             {})
                                                                "GET https://api.test/openapi.json?k=K" {:status 200
                                                                                                         :headers {}
                                                                                                         :raw schema-text}})
                        code (cli.run ["op" "remote" "--list"]
                                      {: transport
                                       :config {:profiles {:remote {:schema "https://api.test/openapi.json"
                                                                    :auth {:name "api-key"
                                                                           :params {:in "query"
                                                                                    :name "k"
                                                                                    :value "K"}}}}}
                                       :schema-cache false})]
                    (assert.are.equal 0 code)
                    (assert.are.equal 2 (length requests))
                    (assert.is_nil (?. requests 1 :query :k)))))
            (it "keeps profile headers and credentials from a spec on another origin"
                (fn []
                  (let [(transport requests) (routes-transport {"GET https://specs.test/openapi.json" (respond 401
                                                                                                               {})})
                        code (cli.run ["op" "remote" "--list"]
                                      {: transport
                                       :config {:profiles {:remote {:schema "https://specs.test/openapi.json"
                                                                    :base-url "https://api.test"
                                                                    :headers {:authorization "Bearer P"}
                                                                    :auth {:name "bearer"
                                                                           :params {:token "t"}}}}}
                                       :schema-cache false})]
                    (assert.are.equal 1 code)
                    (assert.are.equal 1 (length requests))
                    (assert.is_nil (. requests 1 :headers :authorization)))))))

(describe "ezu az"
          (fn []
            (it "runs a workflow with the context's profile and prints outputs in its format"
                (fn []
                  (let [r (ezu-run ["az" "flows" "fetchPet" "id=7"]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {:name "Rex"})})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "name: Rex" r.out))))
            (it "says why a condition can't be evaluated"
                (fn []
                  (let [json (require :ezu.json)
                        flow (with-open [f (io.open "test/fixtures/cli-flow.arazzo.json")]
                               (json.decode (f:read :*a)))
                        file (.. (os.tmpname) ".json")]
                    (set (. flow :workflows 1 :steps 1 :successCriteria)
                         [{:condition "$statuscode == 200"}])
                    (set (. flow :sourceDescriptions 1 :url)
                         (.. (os.getenv "PWD") "/test/fixtures/cli-api.json"))
                    (with-open [f (io.open file :w)]
                      (f:write (json.encode flow)))
                    (let [r (ezu-run ["az" file "fetchPet" "id=7"]
                                     {"GET https://api.test/pets/7" (respond 200
                                                                             {:name "Rex"})})]
                      (os.remove file)
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find "warning: condition '$statuscode == 200' can't be evaluated"
                                                    1 true))))))
            (it "selects in the outputs"
                (fn []
                  (let [r (ezu-run ["az"
                                    "flows"
                                    "fetchPet"
                                    "id=7"
                                    "--select=.name"
                                    "--output=raw"]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {:name "Rex"})})]
                    (assert.are.equal 0 r.code r.err)
                    (assert.are.equal "Rex" r.out))))
            (it "prints a single list output as rows"
                (fn []
                  (let [json (require :ezu.json)
                        flow (with-open [f (io.open "test/fixtures/cli-flow.arazzo.json")]
                               (json.decode (f:read :*a)))
                        file (.. (os.tmpname) ".json")]
                    (set (. flow :sourceDescriptions 1 :url)
                         (.. (os.getenv "PWD") "/test/fixtures/cli-api.json"))
                    (table.insert flow.workflows
                                  {:workflowId "listPets"
                                   :steps [{:stepId "list"
                                            :operationId "listPets"
                                            :outputs {:pets "$response.body"}}]
                                   :outputs {:pets "$steps.list.outputs.pets"}})
                    (with-open [f (io.open file :w)]
                      (f:write (json.encode flow)))
                    (let [routes {"GET https://api.test/pets" (respond 200
                                                                       [{:id 1
                                                                         :name "Rex"}
                                                                        {:id 2
                                                                         :name "Bo"}])}
                          rows (ezu-run ["az" file "listPets" "--output=csv"]
                                        routes)
                          picked (ezu-run ["az"
                                           file
                                           "listPets"
                                           "--output=csv"
                                           "--select=.pets[].{name}"]
                                          routes)]
                      (os.remove file)
                      (assert.are.equal 0 rows.code rows.err)
                      (assert.are.equal "id,name\n1,Rex\n2,Bo" rows.out)
                      (assert.are.equal "name\nRex\nBo" picked.out)))))
            (it "prints outputs as a table row"
                (fn []
                  (let [r (ezu-run ["az"
                                    "flows"
                                    "fetchPet"
                                    "id=7"
                                    "--output=csv"]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {:name "Rex"})})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "name\nRex" r.out))))
            (it "validates workflow inputs against the inputs schema"
                (fn []
                  (let [r (ezu-run ["az"
                                    "flows"
                                    "fetchPet"
                                    "--inputs"
                                    "{\"id\": 7}"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "inputs.id: expected string, got integer"
                                                  1 true))
                    (assert.are.equal 0 (length r.requests)))))
            (it "prints each step's response with --arazzo-output steps"
                (fn []
                  (let [r (ezu-run ["az"
                                    "flows"
                                    "fetchPet"
                                    "id=7"
                                    "--arazzo-output"
                                    "steps"]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {:name "Rex"})})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "--- get ---\nname: Rex\n--- outputs ---\nname: Rex"
                                      r.out))))
            (it "prints requests and responses with --arazzo-output full"
                (fn []
                  (let [r (ezu-run ["az"
                                    "flows"
                                    "fetchPet"
                                    "id=7"
                                    "--arazzo-output"
                                    "full"]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {:name "Rex"})})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "--- get request ---\noperation: getPet\n--- get response HTTP 200 ---\nname: Rex\n--- outputs ---\nname: Rex"
                                      r.out))))
            (it "takes inputs as name=value, typed, over --inputs"
                (fn []
                  (let [r (ezu-run ["az"
                                    "flows"
                                    "fetchPet"
                                    "--inputs"
                                    "{\"id\": \"1\"}"
                                    "id=7"]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {:name "Rex"})})]
                    (assert.are.equal 0 r.code r.err)
                    (assert.are.equal 1 (length r.requests)))))
            (it "refuses a name it doesn't know, saying which it meant"
                (fn []
                  (let [r (ezu-run ["az" "flows" "fetchPet" "idd=7"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "no input 'idd' in fetchPet; did you mean id?"
                                                  1 true)
                                      r.err)
                    (assert.are.equal 0 (length r.requests)))))
            (it "takes positional values only for the inputs a workflow declares"
                (fn []
                  (let [r (ezu-run ["az" "flows" "fetchPet" "7"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "fetchPet takes no positional arguments: give inputs as name=value"
                                                  1 true)
                                      r.err))
                  (let [json (require :ezu.json)
                        flow (with-open [f (io.open "test/fixtures/cli-flow.arazzo.json")]
                               (json.decode (f:read :*a)))
                        file (.. (os.tmpname) ".json")]
                    (set (. flow :sourceDescriptions 1 :url)
                         (.. (os.getenv "PWD") "/test/fixtures/cli-api.json"))
                    (set (. flow :workflows 1 :x-ezu-args) ["id"])
                    (with-open [f (io.open file :w)]
                      (f:write (json.encode flow)))
                    (let [routes {"GET https://api.test/pets/7" (respond 200
                                                                         {:name "Rex"})
                                  "GET https://api.test/pets/aGVsbG8=" (respond 200
                                                                                {:name "Bas"})
                                  "GET https://api.test/pets/aGVsbG8%3D" (respond 200
                                                                                  {:name "Bas"})}
                          ok (ezu-run ["az" file "fetchPet" "7"] routes)
                          literal (ezu-run ["az"
                                            file
                                            "fetchPet"
                                            "--output=yaml"
                                            "--"
                                            "aGVsbG8="]
                                           routes)
                          extra (ezu-run ["az" file "fetchPet" "7" "8"] routes)
                          lookalike (ezu-run ["az" file "fetchPet" "aGVsbG8="]
                                             routes)
                          help (ezu-run ["az" file "fetchPet" "--help"])]
                      (os.remove file)
                      (assert.are.equal 0 ok.code ok.err)
                      (assert.are.equal 1 extra.code)
                      (assert.is_truthy (extra.err:find "fetchPet takes 1 positional argument (id), not 8"
                                                        1 true)
                                        extra.err)
                      (assert.are.equal 1 lookalike.code)
                      (assert.is_truthy (lookalike.err:find "to pass it as id, write id=aGVsbG8= or put it after --"
                                                            1 true)
                                        lookalike.err)
                      ;; after --, a value shaped like name=value is a value
                      (assert.are.equal 0 literal.code literal.err)
                      (assert.are.equal "name: Bas" literal.out)
                      (assert.is_truthy (help.out:find "fetchPet <id> [name=value ...]"
                                                       1 true)
                                        help.out)))))
            (it "says how inputs are given now to -i and --i."
                (fn []
                  (each [_ args (ipairs [["-i" "id=7"]
                                         ["--i.id=7"]
                                         ["--input.id=7"]])]
                    (let [r (ezu-run (doto ["az" "flows" "fetchPet"]
                                       (#(each [_ a (ipairs args)]
                                           (table.insert $ a)))))]
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find "workflow inputs are name=value arguments, like id=7"
                                                    1 true)
                                        r.err)))))
            (it "lists the workflows of a document"
                (fn []
                  (let [r (ezu-run ["az" "flows"])]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "fetchPet" r.out))))
            (it "prints workflow help"
                (fn []
                  (let [r (ezu-run ["az" "flows" "fetchPet" "--help"])]
                    (assert.are.equal 0 r.code)
                    (assert.is_truthy (r.out:find "fetchPet" 1 true))
                    (assert.are.equal 0 (length r.requests)))))
            (it "escapes control characters of step ids"
                (fn []
                  (let [file (.. (os.tmpname) ".json")]
                    (with-open [f (io.open file :w)]
                      (f:write "{\"arazzo\":\"1.0.0\",\"info\":{},\"sourceDescriptions\":[{\"name\":\"api\",\"type\":\"openapi\",\"url\":\""
                               (os.getenv :PWD)
                               "/test/fixtures/cli-api.json\"}],\"workflows\":[{\"workflowId\":\"w\",\"steps\":[{\"stepId\":\"s\\u001b]0;P\\u0007\",\"operationId\":\"getPet\",\"parameters\":[{\"name\":\"id\",\"in\":\"path\",\"value\":7}]}]}]}"))
                    (let [routes {"GET https://api.test/pets/7" (respond 200
                                                                         {:name "Rex"})}
                          verbose (ezu-run ["az" file "w" "-v"] routes)
                          steps (ezu-run ["az"
                                          file
                                          "w"
                                          "--arazzo-output"
                                          "full"]
                                         routes)]
                      (os.remove file)
                      (assert.are.equal 0 verbose.code)
                      (assert.is_nil (verbose.err:find "\27" 1 true))
                      (assert.is_nil (steps.out:find "\27" 1 true))
                      (assert.is_truthy (steps.out:find "\\x1B" 1 true))))))
            (it "lists workflows whose id is not a string"
                (fn []
                  (let [file (.. (os.tmpname) ".json")]
                    (with-open [f (io.open file :w)]
                      (f:write "{\"arazzo\":\"1.0.0\",\"info\":{},\"workflows\":[{\"workflowId\":5,\"steps\":[]},{\"steps\":[]}]}"))
                    (let [r (ezu-run ["az" file])]
                      (os.remove file)
                      (assert.are.equal 0 r.code)
                      (assert.is_truthy (r.out:find "5" 1 true))))))
            (it "rejects an unknown profile"
                (fn []
                  (let [r (ezu-run ["az"
                                    "flows"
                                    "fetchPet"
                                    "id=7"
                                    "--profile"
                                    "typo"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "Profile not found: typo" 1
                                                  true))
                    (assert.are.equal 0 (length r.requests)))))
            (it "rejects unknown workflows and --dry-run"
                (fn []
                  (let [r (ezu-run ["az" "flows" "nope"])]
                    (assert.are.equal 1 r.code)
                    (assert.are.equal "Unknown workflow: nope\n" r.err))
                  (let [r (ezu-run ["az" "flows" "fetchPet" "--dry-run"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "not supported for az" 1 true)))))
            (it "reports a failed workflow in progress mode"
                (fn []
                  (let [r (ezu-run ["az"
                                    "flows"
                                    "fetchPet"
                                    "id=7"
                                    "--arazzo-output"
                                    "progress"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "workflow fetchPet failed" 1
                                                  true))
                    (assert.is_truthy (r.err:find "✗" 1 true))
                    (assert.is_truthy (r.err:find "1/1 get  getPet" 1 true)))))
            (it "shows each step's result in progress mode, not its outputs"
                (fn []
                  (let [r (ezu-run ["az"
                                    "flows"
                                    "fetchPet"
                                    "id=7"
                                    "--arazzo-output"
                                    "progress"]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {:name "Rex"})})]
                    (assert.are.equal 0 r.code)
                    (assert.is_truthy (r.err:find "1/1 get  getPet  %d+ms  .*200"))
                    (assert.is_truthy (r.err:find "workflow fetchPet  %d+ms"))
                    (assert.is_nil (r.err:find "Rex" 1 true))
                    (assert.are.equal "name: Rex" r.out))))
            (it "checks a document without running it"
                (fn []
                  (let [r (ezu-run ["az" "flows" "--check"])]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal 0 (length r.requests))
                    (assert.is_truthy (r.out:find "nothing wrong found" 1 true)
                                      r.out))))
            (it "refuses to check a workflow that doesn't exist"
                (fn []
                  (let [r (ezu-run ["az" "flows" "fetchPett" "--check"])]
                    (assert.are.equal 1 r.code)
                    (assert.are.equal "Unknown workflow: fetchPett; did you mean fetchPet?\n"
                                      r.err))))
            (it "lists what is wrong in a document, and fails"
                (fn []
                  (let [json (require :ezu.json)
                        flow (with-open [f (io.open "test/fixtures/cli-flow.arazzo.json")]
                               (json.decode (f:read :*a)))
                        file (.. (os.tmpname) ".json")]
                    (set (. flow :sourceDescriptions 1 :url)
                         (.. (os.getenv "PWD") "/test/fixtures/cli-api.json"))
                    (set (. flow :workflows 1 :steps 1 :operationId) "getPett")
                    (set (. flow :workflows 1 :outputs)
                         {:x "$steps.nope.outputs.y"})
                    (with-open [f (io.open file :w)]
                      (f:write (json.encode flow)))
                    (let [r (ezu-run ["az" file "--check"])
                          one (ezu-run ["az" file "fetchPet" "--check"])]
                      (os.remove file)
                      (assert.are.equal 1 r.code)
                      (assert.are.equal 0 (length r.requests))
                      (assert.is_truthy (r.out:find "✗ fetchPet › step get: operation not found: getPett"
                                                    1 true)
                                        r.out)
                      (assert.is_truthy (r.out:find "unknown step 'nope'" 1
                                                    true))
                      (assert.is_truthy (r.out:find "2 errors" 1 true) r.out)
                      ;; a workflow's own problems, its steps' included
                      (assert.are.equal 1 one.code)
                      (assert.is_truthy (one.out:find "step get: operation not found"
                                                      1 true)
                                        one.out)))))
            (it "fails with exit 1 when a step fails"
                (fn []
                  (let [r (ezu-run ["az" "flows" "fetchPet" "id=7"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "step 'get' failed: $statusCode == 200 ($statusCode is 404); HTTP 404"
                                                  1 true)))))))

(describe "other commands"
          (fn []
            (it "prints usage without arguments"
                (fn []
                  (let [r (ezu-run [])]
                    (assert.are.equal 0 r.code)
                    (assert.is_truthy (r.out:find "Usage: ezu" 1 true)))))
            (it "prints its version and the HTTP library it uses"
                (fn []
                  (let [r (ezu-run ["--version"])
                        version (. (require :ezu) :version)]
                    (assert.are.equal 0 r.code)
                    (assert.is_truthy (version:match "^%d+%.%d+%.%d+"))
                    (assert.is_truthy (r.out:find (.. "ezu " version
                                                      " (libcurl/")
                                                  1 true)))))
            (it "lists --licenses in its usage"
                (fn []
                  (let [r (ezu-run [])]
                    (assert.is_truthy (r.out:find "--licenses" 1 true)))))
            (it "prints the licenses of the software in the binary"
                (fn []
                  (tset package.preload :ezu.third-party
                        #"# Third-party software\n\n## Lua 5.4\n")
                  (let [r (ezu-run ["--licenses"])]
                    (tset package.preload :ezu.third-party nil)
                    (tset package.loaded :ezu.third-party nil)
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "# Third-party software\n\n## Lua 5.4"
                                      r.out))))
            (it "says where the licenses are when it isn't the binary"
                (fn []
                  (let [r (ezu-run ["--licenses"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "THIRD-PARTY.md" 1 true)))))
            (it "lists profiles sorted"
                (fn []
                  (let [r (ezu-run ["profile" "list"])]
                    (assert.are.equal "broken-auth\ttest/fixtures/cli-api.json\ncounted\ttest/fixtures/cli-api.json\np\ttest/fixtures/cli-api.json\nyaml\ttest/fixtures/cli-api.json"
                                      r.out))))
            (it "prints static credentials for ezu auth"
                (fn []
                  (assert.are.equal "authorization: Bearer t0k"
                                    (. (ezu-run ["auth" "p"]) :out))))
            (it "rejects options given to completion"
                (fn []
                  (let [r (ezu-run ["completion" "bash" "--dry-run"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "--dry-run doesn't apply to completion"
                                                  1 true)))))
            (it "explains missing profile arguments"
                (fn []
                  (let [r (ezu-run ["profile"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "Usage: ezu profile" 1 true))
                    (assert.is_nil (r.err:find "nil" 1 true)))
                  (let [r (ezu-run ["profile" "show"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "Usage: ezu profile show <name>"
                                                  1 true)))))
            (it "explains field paths without a name and inputs that are not objects"
                (fn []
                  (each [_ [args msg] (ipairs [[["op" "p" "add-pet" "--b..=1"]
                                                "has no field name"]
                                               [["az"
                                                 "flows"
                                                 "fetchPet"
                                                 "--inputs"
                                                 "5"]
                                                "--inputs must be an object"]
                                               [["az"
                                                 "flows"
                                                 "fetchPet"
                                                 "-d"
                                                 "\"s\""]
                                                "doesn't apply to az"]])]
                    (let [r (ezu-run args)]
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find msg 1 true) r.err)))))
            (it "keeps the cached token when signing in again fails"
                (fn []
                  (let [auth (require :ezu.auth)
                        socket (require :socket)
                        srv (assert (socket.bind "127.0.0.1" 0))
                        (_ port) (srv:getsockname)]
                    (srv:close)
                    (auth.save-token "oc-keep"
                                     {:access_token "old" :refresh_token "r"})
                    (let [r (with-config {:profiles {:oc-keep {:auth {:name "oauth-client-credentials"
                                                                      :params {:token_url (.. "http://127.0.0.1:"
                                                                                              port
                                                                                              "/token")
                                                                               :client_id "c"
                                                                               :client_secret "s"}}}}}
                              #(ezu-run ["auth" "oc-keep"]))
                          kept (auth.load-token "oc-keep")]
                      (auth.clear-token "oc-keep")
                      (assert.are.equal 1 r.code)
                      (assert.are.equal "old" (?. kept :access_token))))))
            (it "takes --timeout for the token endpoint"
                (fn []
                  (let [r (ezu-run ["auth" "p" "--timeout" "5"])]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "authorization: Bearer t0k" r.out))))
            (it "shows a query API key read from the environment"
                (fn []
                  (let [r (with-config {:profiles {:qkenv {:auth {:name "api-key"
                                                                  :params {:in "query"
                                                                           :name "key"
                                                                           :value "env:EZU_TEST_UNSET_KEY"}}}}}
                            #(ezu-run ["auth" "qkenv"]))]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "EZU_TEST_UNSET_KEY" 1 true)))
                  (let [r (with-config {:profiles {:qkenv {:auth {:name "api-key"
                                                                  :params {:in "query"
                                                                           :name "key"
                                                                           :value "env:HOME"}}}}}
                            #(ezu-run ["auth" "qkenv"]))]
                    (assert.are.equal (.. "query: key=" (os.getenv :HOME))
                                      r.out))))
            (it "rejects unknown TLS options and non-positive timeouts"
                (fn []
                  (each [_ [args msg] (ipairs [[["op"
                                                 "p"
                                                 "--list"
                                                 "--ssl.cert=c.pem"]
                                                "unknown TLS option: cert (expected cafile, capath, certificate, key or verify)"]
                                               [["op"
                                                 "p"
                                                 "--list"
                                                 "--timeout=-5"]
                                                "--timeout must be greater than 0"]
                                               [["op"
                                                 "p"
                                                 "--list"
                                                 "--timeout=0"]
                                                "--timeout must be greater than 0"]])]
                    (let [r (ezu-run args)]
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find msg 1 true) r.err)))))
            (it "rejects a config with the wrong shape"
                (fn []
                  (each [_ [cfg msg] (ipairs [[{:profiles "x"}
                                               "config: profiles must be an object"]
                                              [{:profiles [1]}
                                               "config: profiles must be an object"]
                                              [3
                                               "config must be a JSON object"]
                                              [{:profiles {:a {:schema 5}}}
                                               "profile a: schema must be a string"]])]
                    ;; profile list marks a broken profile and goes on
                    (let [r (with-config cfg
                              #(ezu-run ["op" "a" "--list"]))
                          listed (with-config cfg
                                   #(ezu-run ["profile" "list"]))]
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find msg 1 true) r.err)
                      (assert.is_truthy (: (.. listed.out listed.err) :find msg
                                           1 true))))))
            (it "lists, shows and logs out of a profile whose auth is incomplete"
                (fn []
                  (with-config {:profiles {:nopw {:schema "test/fixtures/cli-api.json"
                                                  :auth {:name "basic"
                                                         :params {:username "me"}}}}}
                    #(each [_ args (ipairs [["op" "nopw" "--list"]
                                            ["op" "nopw" "list-pets" "--help"]
                                            ["profile" "show" "nopw"]
                                            ["auth" "nopw" "--logout"]])]
                       (assert.are.equal 0 (. (ezu-run args) :code)
                                         (table.concat args " "))))))
            (it "adds a cookie API key to the cookies already sent"
                (fn []
                  (let [cfg {:profiles {:ck {:schema "test/fixtures/cli-api.json"
                                             :headers {:Cookie "theme=dark"}
                                             :auth {:name "api-key"
                                                    :params {:in "cookie"
                                                             :name "sid"
                                                             :value "S"}}}}}
                        routes {"GET https://api.test/pets" (respond 200 [])}
                        r (with-config cfg
                            #(ezu-run ["op" "ck" "list-pets"] routes))
                        mine (with-config cfg
                               #(ezu-run ["op"
                                          "ck"
                                          "list-pets"
                                          "--h.cookie=sid=MINE"]
                                         routes))
                        cookie (fn [run]
                                 (let [util (require :ezu.util)]
                                   (util.header (. run.requests 1 :headers)
                                                "cookie")))]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "theme=dark; sid=S" (cookie r))
                    (assert.are.equal "sid=MINE" (cookie mine)))))
            (it "doesn't authenticate when the request already sends the key's cookie"
                (fn []
                  (let [r (with-config {:profiles {:ce {:schema "test/fixtures/cli-api.json"
                                                        :auth {:name "api-key"
                                                               :params {:in "cookie"
                                                                        :name "session"
                                                                        :value "env:EZU_TEST_UNSET_KEY"}}}}}
                            #(ezu-run ["op"
                                       "ce"
                                       "list-pets"
                                       "--h.Cookie=session=mine"]
                                      {"GET https://api.test/pets" (respond 200
                                                                            [])}))]
                    (assert.are.equal 0 r.code r.err))))
            (it "fetches a spec with the cookie key after a 401, next to the profile's cookies"
                (fn []
                  (let [schema-text (with-open [f (io.open "test/fixtures/cli-api.json")]
                                      (f:read :*a))
                        util (require :ezu.util)
                        (transport requests) (routes-transport {"GET https://api.test/openapi.json" (fn [req]
                                                                                                      (if (: (or (util.header req.headers
                                                                                                                              :cookie)
                                                                                                                 "")
                                                                                                             :find
                                                                                                             "session=S1"
                                                                                                             1
                                                                                                             true)
                                                                                                          {:status 200
                                                                                                           :headers {}
                                                                                                           :raw schema-text}
                                                                                                          (respond 401
                                                                                                                   {})))})
                        code (cli.run ["op" "ckh" "--list"]
                                      {: transport
                                       :config {:profiles {:ckh {:schema "https://api.test/openapi.json"
                                                                 :headers {:Cookie "pref=1"}
                                                                 :auth {:name "api-key"
                                                                        :params {:in "cookie"
                                                                                 :name "session"
                                                                                 :value "S1"}}}}}
                                       :schema-cache false})]
                    (assert.are.equal 0 code)
                    (assert.are.equal 2 (length requests)))))
            (it "names the auth parameters a profile is missing"
                (fn []
                  (each [_ [auth msg] (ipairs [[{:name "oauth-client-credentials"
                                                 :params {:client_id "c"}}
                                                "oauth-client-credentials auth requires params.token_url"]
                                               [{:name "oauth-client-credentials"}
                                                "oauth-client-credentials auth requires params.token_url"]
                                               [{:name "external-tool"}
                                                "external-tool auth requires params.commandline"]])]
                    (let [r (with-config {:profiles {:bad {:schema "test/fixtures/cli-api.json"
                                                           : auth}}}
                              #(ezu-run ["auth" "bad"]))]
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find msg 1 true) r.err)))))
            (it "rejects Arazzo contexts and extends of the wrong shape"
                (fn []
                  (each [_ [cfg args msg] (ipairs [[{:arazzo {:pets "/x/wf.yaml"}}
                                                    ["az" "pets"]
                                                    "config: arazzo pets must be an object with a file"]
                                                   [{:arazzo {:m {:file "wf.yaml"
                                                                  :inputs "str"}}}
                                                    ["az" "m" "go"]
                                                    "config: arazzo m: inputs must be an object"]
                                                   [{:profiles {:x {:schema "s.json"
                                                                    :extends "y"}
                                                                :y "oops"}}
                                                    ["op" "x" "--list"]
                                                    "profile y must be an object"]])]
                    (let [r (with-config cfg #(ezu-run args))]
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find msg 1 true) r.err)))
                  (let [r (with-config {:profiles {:x {:schema "s.json"
                                                       :extends "y"}
                                                   :y "oops"}}
                            #(ezu-run ["profile" "list"]))]
                    (assert.is_nil (r.out:find ".lua:" 1 true) r.out))))
            (it "rejects profiles whose settings have the wrong shape"
                (fn []
                  (each [_ [profile msg] (ipairs [[{:schema "test/fixtures/cli-api.json"
                                                    :auth "bearer"}
                                                   "profile bad: auth must be an object"]
                                                  [{:schema "test/fixtures/cli-api.json"
                                                    :headers "x"}
                                                   "profile bad: headers must be an object"]
                                                  [{:schema "test/fixtures/cli-api.json"
                                                    :auth {:params {}}}
                                                   "profile bad: auth needs a name"]])]
                    (let [r (with-config {:profiles {:bad profile}}
                              #(ezu-run ["op" "bad" "list-pets"]))]
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find msg 1 true) r.err)))))
            (it "tells what ezu auth adds besides headers"
                (fn []
                  (with-config {:profiles {:qkey {:auth {:name "api-key"
                                                         :params {:in "query"
                                                                  :name "appid"
                                                                  :value "K"}}}
                                           :sign {:auth {:name "external-tool"
                                                         :params {:commandline "sign-it"}}}}}
                    #(do
                       (assert.are.equal "query: appid=K"
                                         (. (ezu-run ["auth" "qkey"]) :out))
                       (assert.are.equal "signs each request with: sign-it"
                                         (. (ezu-run ["auth" "sign"]) :out))))))
            (it "rejects unknown commands with exit 1"
                (fn []
                  (assert.are.equal 1 (. (ezu-run ["frobnicate"]) :code))))
            (it "lists the schema a profile inherits"
                (fn []
                  (let [r (with-config {:profiles {:base {:schema "s.json"}
                                                   :child {:extends "base"}}}
                            #(ezu-run ["profile" "list"]))]
                    (assert.are.equal "base\ts.json\nchild\ts.json" r.out))))
            (it "lists every profile, flagging one whose extends is broken"
                (fn []
                  (let [r (with-config {:profiles {:a {:schema "s.json"}
                                                   :b {:extends "nope"}
                                                   :c {:schema "t.json"}}}
                            #(ezu-run ["profile" "list"]))]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "a\ts.json\nb\t(broken: Profile not found: nope)\nc\tt.json"
                                      r.out))))
            (it "rejects options that don't apply to the command"
                (fn []
                  (let [r (ezu-run ["op" "p" "get-pet" "3" "--profile" "yaml"])]
                    (assert.are.equal 1 r.code)
                    (assert.are.equal "--profile doesn't apply to op (it is for az)\n"
                                      r.err)
                    (assert.are.equal 0 (length r.requests)))
                  (let [r (ezu-run ["az" "flows" "fetchPet" "--list"])]
                    (assert.are.equal 1 r.code)
                    (assert.are.equal "--list doesn't apply to az (it is for op)\n"
                                      r.err))
                  (let [r (ezu-run ["op" "p" "get-pet" "3" "--logout"])]
                    (assert.are.equal 1 r.code)
                    (assert.are.equal "--logout doesn't apply to op (it is for auth)\n"
                                      r.err))))
            (it "scopes options to profile and auth too"
                (fn []
                  (let [r (ezu-run ["profile" "list" "--timeout" "3"])]
                    (assert.are.equal 1 r.code)
                    (assert.are.equal "--timeout doesn't apply to profile (it is for op, az and http)\n"
                                      r.err))
                  (let [r (ezu-run ["profile" "list" "--dry-run"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "--dry-run only applies to profile import-restish"
                                                  1 true)))
                  (let [r (ezu-run ["auth" "p" "--base-url" "http://x"])]
                    (assert.are.equal 1 r.code))
                  (assert.are.equal "authorization: Bearer t0k"
                                    (. (ezu-run ["auth"
                                                 "p"
                                                 "--ssl.verify=none"])
                                       :out))))
            (it "prints usage for --help on profile and auth, doing nothing else"
                (fn []
                  (each [_ args (ipairs [["auth" "p" "--help"]
                                         ["profile"
                                          "import-restish"
                                          "x.json"
                                          "--help"]])]
                    (let [r (ezu-run args)]
                      (assert.are.equal 0 r.code)
                      (assert.is_truthy (r.out:find "Usage: ezu" 1 true))
                      (assert.is_nil (r.out:find "Bearer" 1 true))))))
            (it "checks server variables when listing servers"
                (fn []
                  (let [r (ezu-run ["op" "p" "--servers" "--server.region=xx"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "unknown server variable 'region'"
                                                  1 true)))))
            (it "explains bad option values"
                (fn []
                  (let [r (ezu-run ["op" "p" "get-pet" "3" "--output=yml"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "--output must be one of json, yaml, raw, table, csv, tsv, status, headers"
                                                  1 true)))
                  (let [r (ezu-run ["op" "p" "get-pet" "3" "--server-index=0"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "server index 0 out of range"
                                                  1 true)))
                  (let [r (ezu-run ["op" "p" "add-pet" "--b.=1"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "--b. needs a field name" 1
                                                  true)))))
            (it "shows a profile, or fails when it does not exist"
                (fn []
                  (let [r (ezu-run ["profile" "show" "yaml"])]
                    (assert.are.equal 0 r.code)
                    (assert.is_truthy (r.out:find "test/fixtures/cli-api.json"
                                                  1 true)))
                  (let [r (ezu-run ["profile" "show" "nope"])]
                    (assert.are.equal 1 r.code)
                    (assert.are.equal "Profile not found: nope\n" r.err))))
            (it "rejects unknown profile subcommands"
                (fn []
                  (let [r (ezu-run ["profile" "frob"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "Unknown profile subcommand: frob"
                                                  1 true)))))
            (it "explains what ezu auth needs"
                (fn []
                  (assert.are.equal "Usage: ezu auth <profile> [--logout]\n"
                                    (. (ezu-run ["auth"]) :err))
                  (assert.are.equal "Profile not found: nope\n"
                                    (. (ezu-run ["auth" "nope"]) :err))
                  (assert.are.equal "No auth configured for profile: yaml\n"
                                    (. (ezu-run ["auth" "yaml"]) :err))
                  (assert.is_truthy (: (. (ezu-run ["auth" "broken-auth"]) :err)
                                       :find
                                       "external auth command failed (exit 1)" 1
                                       true))))
            (it "logs out of a profile"
                (fn []
                  (let [r (ezu-run ["auth" "p" "--logout"])]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "Logged out: p" r.out))))
            (it "lists configured profiles and contexts when op or az has no target"
                (fn []
                  (let [r (ezu-run ["op"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "Configured profiles:\n  broken-auth\ttest/fixtures/cli-api.json\n"
                                                  1 true)))
                  (let [r (ezu-run ["az"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "Configured Arazzo contexts:\n  flows\ttest/fixtures/cli-flow.arazzo.json\n"
                                                  1 true)))))
            (it "answers the shell scripts' completion requests"
                (fn []
                  (assert.are.equal "import-restish"
                                    (. (ezu-run ["__complete" "ezu profile im"])
                                       :out))
                  (assert.are.equal "--verbose\tShow status, headers and requests"
                                    (. (ezu-run ["__complete"
                                                 "--describe"
                                                 "ezu op x --verb"])
                                       :out))
                  (assert.are.equal "" (. (ezu-run ["__complete" "ezu"]) :out))))
            (it "prints completion scripts for each shell"
                (fn []
                  (each [_ shell (ipairs ["fish" "bash" "zsh"])]
                    (let [r (ezu-run ["completion" shell])]
                      (assert.are.equal 0 r.code)
                      (assert.is_truthy (r.out:find "__complete" 1 true))))
                  (assert.are.equal 1 (. (ezu-run ["completion" "tcsh"]) :code))))))

(describe "credentials and schema sources"
          (fn []
            (let [schema-text (let [f (io.open "test/fixtures/cli-api.json")
                                    s (f:read :*a)]
                                (f:close)
                                s)
                  remote-config {:profiles {:remote {:schema "https://api.test/openapi.json"
                                                     :headers {:authorization "Basic profile"}
                                                     :auth {:name "bearer"
                                                            :params {:token "t"}}}
                                            :tok {:auth {:name "bearer"
                                                         :params {:token "t"}}}}
                                 :arazzo {:remote-flow {:file "test/fixtures/cli-remote.arazzo.json"
                                                        :profile "tok"}}}
                  run-with (fn [args routes]
                             (let [(transport requests) (routes-transport routes)
                                   real-print _G.print
                                   real-stderr io.stderr
                                   err []]
                               (set _G.print (fn []))
                               (set io.stderr
                                    {:write (fn [_ s] (table.insert err s))})
                               (let [code (cli.run args
                                                   {: transport
                                                    :config remote-config
                                                    :schema-cache false})]
                                 (set _G.print real-print)
                                 (set io.stderr real-stderr)
                                 (values code requests (table.concat err)))))]
              (it "keeps an explicit Authorization header when retrying a schema fetch after 401"
                  (fn []
                    (let [(code requests) (run-with ["op" "remote" "--list"]
                                                    {"GET https://api.test/openapi.json" (fn [req]
                                                                                           (if (= (length (or req.headers.authorization
                                                                                                              ""))
                                                                                                  0)
                                                                                               (respond 401
                                                                                                        {})
                                                                                               (respond 401
                                                                                                        {})))})]
                      (assert.are.equal 1 code)
                      (assert.are.equal 2 (length requests))
                      (assert.are.equal "Basic profile"
                                        (. requests 2 :headers :authorization)))))
              (it "does not send credentials to az sources until they ask"
                  (fn []
                    (let [f (io.open "test/fixtures/cli-remote.arazzo.json" :w)]
                      (f:write "{\"arazzo\":\"1.0.0\",\"info\":{\"title\":\"r\",\"version\":\"1\"},\"sourceDescriptions\":[{\"name\":\"api\",\"type\":\"openapi\",\"url\":\"https://specs.test/openapi.json\"}],\"workflows\":[{\"workflowId\":\"w\",\"steps\":[{\"stepId\":\"s\",\"operationId\":\"listPets\"}]}]}")
                      (f:close))
                    (let [(code requests err) (run-with ["az"
                                                         "remote-flow"
                                                         "w"]
                                                        {"GET https://specs.test/openapi.json" {:status 200
                                                                                                :headers {}
                                                                                                :raw schema-text}
                                                         "GET https://api.test/pets" (respond 200
                                                                                              [])})]
                      (os.remove "test/fixtures/cli-remote.arazzo.json")
                      (assert.are.equal 0 code err)
                      (assert.is_nil (. requests 1 :headers :authorization))
                      (assert.are.equal "Bearer t"
                                        (. requests 2 :headers :authorization)))))
              (it "never sends credentials to a host a source's $ref names"
                  (fn []
                    (let [f (io.open "test/fixtures/cli-remote.arazzo.json" :w)]
                      (f:write "{\"arazzo\":\"1.0.0\",\"info\":{\"title\":\"r\",\"version\":\"1\"},\"sourceDescriptions\":[{\"name\":\"api\",\"type\":\"openapi\",\"url\":\"https://specs.test/openapi.json\"}],\"workflows\":[{\"workflowId\":\"w\",\"steps\":[{\"stepId\":\"s\",\"operationId\":\"listPets\"}]}]}")
                      (f:close))
                    (let [spec "{\"openapi\":\"3.0.0\",\"info\":{\"title\":\"t\",\"version\":\"1\"},\"servers\":[{\"url\":\"https://api.test\"}],\"paths\":{\"/pets\":{\"get\":{\"operationId\":\"listPets\",\"responses\":{\"200\":{\"$ref\":\"https://other.test/common.json#/ok\"}}}}}}"
                          (_ requests) (run-with ["az" "remote-flow" "w"]
                                                 {"GET https://specs.test/openapi.json" {:status 200
                                                                                         :headers {}
                                                                                         :raw spec}
                                                  "GET https://other.test/common.json" {:status 401
                                                                                        :headers {}
                                                                                        :raw ""}})]
                      (os.remove "test/fixtures/cli-remote.arazzo.json")
                      (each [_ req (ipairs requests)]
                        (when (req.url:find "other.test" 1 true)
                          (assert.is_nil (?. req :headers :authorization))))))))))

(describe "auth and argument edge cases"
          (fn []
            (fn auth-runs []
              (let [f (io.open "build/test-home/auth-runs")]
                (if f (let [n (length (icollect [_ (: (f:read :*a) :gmatch
                                                      "run")]
                                        1))]
                        (f:close)
                        n) 0)))

            (before_each (fn [] (os.remove "build/test-home/auth-runs")))
            (it "runs the auth flow once for ezu auth"
                (fn []
                  (assert.are.equal "authorization: Bearer tok"
                                    (. (ezu-run ["auth" "counted"]) :out))
                  (assert.are.equal 1 (auth-runs))))
            (it "honors --logout for every auth type"
                (fn []
                  (let [r (ezu-run ["auth" "p" "--logout"])]
                    (assert.are.equal "Logged out: p" r.out))))
            (it "does not authenticate for --dry-run"
                (fn []
                  (let [r (ezu-run ["op" "counted" "get-pet" "1" "--dry-run"])]
                    (assert.are.equal 0 r.code)
                    (assert.is_truthy (r.out:find "authorization: <redacted>" 1
                                                  true))
                    (assert.are.equal 0 (auth-runs)))))
            (it "does not authenticate when an explicit header covers it"
                (fn []
                  (let [r (ezu-run ["op"
                                    "counted"
                                    "get-pet"
                                    "1"
                                    "--h.Authorization=Basic x"]
                                   {"GET https://api.test/pets/1" (respond 200
                                                                           {})})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "Basic x"
                                      (. r.requests 1 :headers :authorization))
                    (assert.are.equal 0 (auth-runs)))))
            (it "rejects extra positional arguments"
                (fn []
                  (let [r (ezu-run ["op" "p" "get-pet" "1" "2"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "get-pet takes 1 path parameter (id), got 2"
                                                  1 true))
                    (assert.are.equal 0 (length r.requests)))))
            (it "rejects workflow inputs on op"
                (fn []
                  (let [r (ezu-run ["op" "p" "list-pets" "-i" "a=1"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "-i is gone: workflow inputs are name=value arguments"
                                                  1 true)))))))

(describe "ezu profile import-restish"
          (fn []
            (let [json (require :lunajson)
                  target "build/test-home/import-config.json"
                  run-import (fn [args config]
                               (let [out []
                                     err []
                                     real-print _G.print
                                     real-stderr io.stderr]
                                 (set _G.print
                                      (fn [...]
                                        (table.insert out
                                                      (table.concat [...] "\t"))))
                                 (set io.stderr
                                      {:write (fn [_ s] (table.insert err s))})
                                 (let [code (cli.run args
                                                     {:config config
                                                      :config-path target})]
                                   (set _G.print real-print)
                                   (set io.stderr real-stderr)
                                   {: code
                                    :out (table.concat out "\n")
                                    :err (table.concat err)})))
                  read-target #(let [f (io.open target)]
                                 (when f
                                   (let [v (json.decode (f:read :*a))]
                                     (f:close)
                                     v)))]
              (before_each (fn []
                             (os.remove target)
                             (os.remove (.. target ".bak"))))
              (it "previews with --dry-run without writing"
                  (fn []
                    (let [r (run-import ["profile"
                                         "import-restish"
                                         "test/fixtures/restish-v1.json"
                                         "--dry-run"]
                                        {})]
                      (assert.are.equal 0 r.code)
                      (assert.is_truthy (r.out:find "\"petstore.staging\"" 1
                                                    true))
                      (assert.is_truthy (r.err:find "devices: 2 spec_files" 1
                                                    true))
                      (assert.is_nil (read-target)))))
              (it "adds profiles to the config, keeping existing ones"
                  (fn []
                    (let [f (io.open target :w)]
                      (f:write "{\"output\": \"yaml\", \"profiles\": {\"petstore\": {\"schema\": \"mine.json\"}}}")
                      (f:close))
                    (let [r (run-import ["profile"
                                         "import-restish"
                                         "test/fixtures/restish-v1.json"]
                                        {:output "yaml"
                                         :profiles {:petstore {:schema "mine.json"}}})
                          written (read-target)]
                      (assert.are.equal 0 r.code)
                      (assert.are.equal "mine.json"
                                        written.profiles.petstore.schema)
                      (assert.are.equal "yaml" written.output)
                      (assert.are.equal "basic"
                                        (. written.profiles "petstore.staging"
                                           :auth :name))
                      (assert.is_not_nil written.profiles.devices)
                      (assert.is_truthy (r.out:find "kept existing profile: petstore"
                                                    1 true))
                      (assert.is_truthy (r.out:find "imported 3 profiles" 1
                                                    true))
                      (assert.is_not_nil (io.open (.. target ".bak")))
                      ;; profiles hold credentials
                      (each [_ path (ipairs [target (.. target ".bak")])]
                        ;; without macOS's @ for extended attributes
                        (let [p (io.popen (.. "ls -l " path))
                              mode (: (p:read :*a) :match "^([^%s@]+)")]
                          (p:close)
                          (assert.are.equal "-rw-------" mode))))))
              (it "keeps the config's null values when rewriting it"
                  (fn []
                    (let [f (io.open target :w)]
                      (f:write "{\"arazzo\": {\"x\": {\"file\": \"f\", \"inputs\": {\"nul\": null}}}}")
                      (f:close))
                    (let [r (run-import ["profile"
                                         "import-restish"
                                         "test/fixtures/restish-v1.json"]
                                        {:arazzo {:x {:file "f"}}})
                          f (io.open target)
                          text (f:read :*a)]
                      (f:close)
                      (assert.are.equal 0 r.code)
                      (assert.is_truthy (text:find "\"nul\": null" 1 true)))))
              (it "fails clearly for a missing file"
                  (fn []
                    (let [r (run-import ["profile"
                                         "import-restish"
                                         "nope/restish.json"]
                                        {})]
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find "nope/restish.json" 1 true))))))))

(fn answers [& resps]
  "A route answering resps in turn, then the last one again."
  (var i 0)
  (fn []
    (set i (math.min (+ i 1) (length resps)))
    (. resps i)))

(describe "--until"
          (fn []
            (it "sends the request again until the condition holds, then prints the last response"
                (fn []
                  (let [r (ezu-run ["op"
                                    "p"
                                    "get-pet"
                                    "7"
                                    "--until"
                                    "$response.body#/state == 'ready'"
                                    "--every=0.01"
                                    "--output=yaml"]
                                   {"GET https://api.test/pets/7" (answers (respond 200
                                                                                    {:state "pending"})
                                                                           (respond 200
                                                                                    {:state "pending"})
                                                                           (respond 200
                                                                                    {:state "ready"}))})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal 3 (length r.requests))
                    (assert.are.equal "state: ready" r.out))))
            (it "works for http requests, on the status too"
                (fn []
                  (let [r (ezu-run ["http"
                                    "https://api.test/up"
                                    "--until"
                                    "$statusCode == 200"
                                    "--every=0.01"]
                                   {"GET https://api.test/up" (answers (respond 503
                                                                                {})
                                                                       (respond 200
                                                                                {:ok true}))})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal 2 (length r.requests)))))
            (it "succeeds when the condition holds, whatever the status (waiting for a deletion)"
                (fn []
                  (let [r (ezu-run ["op"
                                    "p"
                                    "get-pet"
                                    "7"
                                    "--until"
                                    "$statusCode == 404"
                                    "--every=0.01"]
                                   {"GET https://api.test/pets/7" (answers (respond 200
                                                                                    {})
                                                                           (respond 404
                                                                                    {}))})]
                    (assert.are.equal 0 r.code))))
            (it "gives up after --max-time, saying why"
                (fn []
                  (let [r (ezu-run ["op"
                                    "p"
                                    "get-pet"
                                    "7"
                                    "--until"
                                    "$response.body#/state == 'ready'"
                                    "--every=0.01"
                                    "--max-time=0"]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {:state "pending"})})]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "--until condition still false after 1 attempt"
                                                  1 true)
                                      r.err)
                    (assert.is_truthy (r.err:find "($response.body#/state is \"pending\")"
                                                  1 true)
                                      r.err))))
            (it "stops at once on a condition that can't be evaluated"
                (fn []
                  (let [r (ezu-run ["op"
                                    "p"
                                    "get-pet"
                                    "7"
                                    "--until"
                                    "$statuscode == 200"
                                    "--every=0.01"]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {})})]
                    (assert.are.equal 1 r.code)
                    (assert.are.equal 0 (length r.requests))
                    (assert.is_truthy (r.err:find "can't be evaluated" 1 true)))))
            (it "reads a streamed body whole, to check it"
                (fn []
                  (let [r (ezu-run ["http"
                                    "https://api.test/lines"
                                    "--until"
                                    "$response.body#/0/a == 1"
                                    "--every=0.01"]
                                   {"GET https://api.test/lines" (respond-text 200
                                                                               "application/x-ndjson"
                                                                               ["{\"a\":1}\n"
                                                                                "{\"a\":2}\n"])})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal 1 (length r.requests)))))
            (it "refuses what it can't wait for, before sending anything"
                (fn []
                  (each [_ [args why] (ipairs [[["--every=0"]
                                                "--every must be more than 0"]
                                               [["--every=-1"]
                                                "--every must be more than 0"]
                                               [["--max-time=-1"]
                                                "--max-time can't be negative"]
                                               [["--dry-run"]
                                                "--until can't be used with --dry-run or --curl"]
                                               [["--curl"]
                                                "--until can't be used with --dry-run or --curl"]])]
                    (let [r (ezu-run (doto ["op"
                                            "p"
                                            "get-pet"
                                            "7"
                                            "--until"
                                            "$statusCode == 200"]
                                       (#(each [_ a (ipairs args)]
                                           (table.insert $ a)))))]
                      (assert.are.equal 1 r.code why)
                      (assert.is_truthy (r.err:find why 1 true) r.err)
                      (assert.are.equal 0 (length r.requests))))))
            (it "refuses a condition it can't evaluate before sending"
                (fn []
                  (each [_ [condition why] (ipairs [["$statusCode =="
                                                     "can't be evaluated"]
                                                    ["$inputs.id == 1"
                                                     "--until conditions use $statusCode, $method, $url, $request and $response"]])]
                    (let [r (ezu-run ["op"
                                      "p"
                                      "get-pet"
                                      "7"
                                      "--until"
                                      condition])]
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find why 1 true) r.err)
                      (assert.are.equal 0 (length r.requests))))))
            (it "sends POST and PATCH again only with --retry-unsafe"
                (fn []
                  (let [routes {"POST https://api.test/jobs" (respond 200
                                                                      {:state "done"})}
                        refused (ezu-run ["http"
                                          "POST"
                                          "https://api.test/jobs"
                                          "--until"
                                          "$response.body#/state == 'done'"]
                                         routes)
                        allowed (ezu-run ["http"
                                          "POST"
                                          "https://api.test/jobs"
                                          "--until"
                                          "$response.body#/state == 'done'"
                                          "--retry-unsafe"]
                                         routes)]
                    (assert.are.equal 1 refused.code)
                    (assert.is_truthy (refused.err:find "--retry-unsafe" 1 true))
                    (assert.are.equal 0 (length refused.requests))
                    (assert.are.equal 0 allowed.code))))
            (it "knows the request it sends"
                (fn []
                  (let [r (ezu-run ["http"
                                    "https://api.test/up"
                                    "--until"
                                    "$method == 'GET' && $url == 'https://api.test/up'"]
                                   {"GET https://api.test/up" (respond 200 {})})]
                    (assert.are.equal 0 r.code r.err)
                    (assert.are.equal 1 (length r.requests)))))
            (it "needs --until for --every and --max-time"
                (fn []
                  (let [r (ezu-run ["op" "p" "get-pet" "7" "--every=1"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "--every needs --until" 1
                                                  true))
                    (assert.are.equal 0 (length r.requests)))))))

(local checked-api
       {:openapi "3.0.3"
        :info {:title "t" :version "1"}
        :servers [{:url "https://api.test"}]
        :paths {"/pets/{id}" {:get {:operationId "getPet"
                                    :parameters [{:name "id"
                                                  :in "path"
                                                  :required true
                                                  :schema {:type "string"}}]
                                    :responses {:200 {:description "ok"
                                                      :content {"application/json" {:schema {:type "object"
                                                                                             :required ["id"
                                                                                                        "name"
                                                                                                        "secret"]
                                                                                             :properties {:id {:type "integer"}
                                                                                                          :name {:type "string"}
                                                                                                          :secret {:type "string"
                                                                                                                   :writeOnly true}}}}}}
                                                :4XX {:description "error"
                                                      :content {"application/json" {:schema {:type "object"
                                                                                             :required ["message"]}}}}}}}}})

(fn check-run [args resp]
  "ezu op on a spec with response schemas, answering resp, with --check-response."
  (let [json (require :ezu.json)
        file (.. (os.tmpname) ".json")]
    (with-open [f (io.open file :w)]
      (f:write (json.encode checked-api)))
    (let [r (with-config {:profiles {:c {:schema file}}}
              #(ezu-run (doto ["op" "c" "get-pet" "7" "--check-response"]
                          (#(each [_ a (ipairs args)]
                              (table.insert $ a))))
                        {"GET https://api.test/pets/7" resp}))]
      (os.remove file)
      r)))

(describe "running as a workflow document's name"
          (fn []
            (it "runs its workflows as ezu az NAME does"
                (fn []
                  (let [r (ezu-run ["fetchPet" "id=7" "--output=yaml"]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {:name "Rex"})}
                                   "/home/me/.local/bin/flows")]
                    (assert.are.equal 0 r.code r.err)
                    (assert.are.equal "name: Rex" r.out))
                  (let [r (ezu-run [] nil "flows")]
                    (assert.are.equal "fetchPet" r.out))))
            (it "is plain ezu under its own name, or a name nothing is configured for"
                (fn []
                  (each [_ program (ipairs ["/usr/bin/ezu"
                                            "./bin/ezu-bin"
                                            "/usr/bin/other"])]
                    (let [r (ezu-run ["--version"] nil program)]
                      (assert.are.equal 0 r.code)
                      (assert.is_truthy (r.out:find "^ezu ") program)))))
            (it "completes under its own name"
                (fn []
                  (let [script (ezu-run ["completion" "fish"] nil "flows")
                        cands (ezu-run ["__complete" "flows fet"] nil "flows")]
                    (assert.is_truthy (script.out:find "complete -c flows" 1
                                                       true)
                                      script.out)
                    (assert.is_truthy (script.out:find "(flows __complete" 1
                                                       true))
                    (assert.is_nil (script.out:find "ezu" 1 true))
                    (assert.are.equal "fetchPet" cands.out))
                  ;; shell functions of their own: loading both completions
                  ;; mustn't make ezu's call this command
                  (each [_ shell (ipairs [:bash :zsh])]
                    (let [r (ezu-run ["completion" shell] nil "flows")]
                      (assert.is_nil (r.out:find "ezu" 1 true) r.out)
                      (assert.is_truthy (r.out:find "_flows" 1 true) r.out)))))
            (it "tells how to make the command with --link"
                (fn []
                  (let [r (ezu-run ["az" "flows" "--link"])]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "ln -s \"$(command -v ezu)\" ~/.local/bin/flows"
                                      r.out))
                  (let [r (ezu-run ["az"
                                    "test/fixtures/cli-flow.arazzo.json"
                                    "--link"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "--link needs a document named in the configuration"
                                                  1 true)))))))

(describe "workflows of other Arazzo documents"
          (fn []
            (local json (require :ezu.json))

            (fn index-file []
              "An Arazzo file running fetchPet of cli-flow, named by its
absolute path, so not next to it."
              (let [file (.. (os.tmpname) ".json")]
                (with-open [f (io.open file :w)]
                  (f:write (json.encode {:arazzo "1.1.0"
                                         :info {:title "index" :version "1"}
                                         :sourceDescriptions [{:name "flows"
                                                               :type "arazzo"
                                                               :url (.. (os.getenv "PWD")
                                                                        "/test/fixtures/cli-flow.arazzo.json")}]
                                         :workflows [{:workflowId "pet"
                                                      :steps [{:stepId "s"
                                                               :workflowId "$sourceDescriptions.flows.fetchPet"
                                                               :parameters [{:name "id"
                                                                             :value "$inputs.id"}]}]
                                                      :inputs {:type "object"
                                                               :properties {:id {:type "string"}}}
                                                      :outputs {:name "$steps.s.outputs.name"}}]})))
                file))

            (local routes
                   {"GET https://api.test/pets/7" (respond 200 {:name "Rex"})})
            (it "loads one elsewhere only when sources are trusted"
                (fn []
                  (let [file (index-file)
                        refused (ezu-run ["az" file "pet" "id=7"] routes)
                        trusted (ezu-run ["az"
                                          file
                                          "pet"
                                          "id=7"
                                          "--trust-sources"
                                          "--output=yaml"]
                                         routes)
                        configured (with-config (doto (collect [k v (pairs config)]
                                                        k
                                                        v)
                                                  (tset :arazzo
                                                        {:index {:file file
                                                                 :trust-sources true}}))
                                     #(ezu-run ["az"
                                                "index"
                                                "pet"
                                                "id=7"
                                                "--output=yaml"]
                                               routes))]
                    (os.remove file)
                    (assert.are.equal 1 refused.code)
                    (assert.is_truthy (refused.err:find "Arazzo source 'flows' is not next to the document"
                                                        1 true)
                                      refused.err)
                    (assert.are.equal 0 trusted.code trusted.err)
                    (assert.are.equal "name: Rex" trusted.out)
                    (assert.are.equal 0 configured.code configured.err)
                    (assert.are.equal "name: Rex" configured.out))))
            (it "takes a document's output mode from its configuration"
                (fn []
                  (let [cfg (doto (collect [k v (pairs config)] k v)
                              (tset :arazzo
                                    {:flows {:file "test/fixtures/cli-flow.arazzo.json"
                                             :profile "yaml"
                                             :arazzo-output "progress"}}))
                        routes {"GET https://api.test/pets/7" (respond 200
                                                                       {:name "Rex"})}
                        r (with-config cfg
                            #(ezu-run ["az" "flows" "fetchPet" "id=7"] routes))
                        flag (with-config cfg
                               #(ezu-run ["az"
                                          "flows"
                                          "fetchPet"
                                          "id=7"
                                          "--arazzo-output=final"]
                                         routes))
                        bad (with-config (doto (collect [k v (pairs config)] k
                                                 v)
                                           (tset :arazzo
                                                 {:flows {:file "x.json"
                                                          :arazzo-output "loud"}}))
                              #(ezu-run ["az" "flows"]))]
                    (assert.are.equal 0 r.code r.err)
                    (assert.is_truthy (r.err:find "workflow fetchPet" 1 true)
                                      r.err)
                    (assert.are.equal "name: Rex" r.out)
                    ;; the command line wins
                    (assert.are.equal "" flag.err)
                    (assert.are.equal 1 bad.code)
                    (assert.is_truthy (bad.err:find "config: arazzo flows: arazzo-output must be one of final, steps, progress, full"
                                                    1 true)
                                      bad.err))))
            (it "wants trust-sources to be true or false"
                (fn []
                  (let [r (with-config (doto (collect [k v (pairs config)] k v)
                                         (tset :arazzo
                                               {:index {:file "x.json"
                                                        :trust-sources "yes"}}))
                            #(ezu-run ["az" "index"]))]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "config: arazzo index: trust-sources must be true or false"
                                                  1 true)
                                      r.err))))))

(describe "command words"
          (fn []
            (local json (require :ezu.json))

            (fn exo-config []
              "A config naming exo: an index mounting a document of pet
commands, written to a new directory."
              (let [dir (os.tmpname)
                    write (fn [name t]
                            (with-open [f (io.open (.. dir "/" name) :w)]
                              (f:write (json.encode t))))
                    pets (with-open [f (io.open "test/fixtures/cli-flow.arazzo.json")]
                           (json.decode (f:read :*a)))
                    fetch (. pets :workflows 1)]
                (os.remove dir)
                (os.execute (.. "mkdir -p '" dir "'"))
                (set (. pets :sourceDescriptions 1 :url)
                     (.. (os.getenv "PWD") "/test/fixtures/cli-api.json"))
                (set pets.info
                     {:title "pets" :version "1" :summary "Pet commands"})
                (set fetch.summary "Fetch a pet")
                (set (. fetch :x-ezu-command) "pet get")
                (set (. fetch :x-ezu-args) [:id])
                (write "pets.json" pets)
                (write "index.json"
                       {:arazzo "1.1.0"
                        :info {:title "exo" :version "1"}
                        :sourceDescriptions [{:name "pets"
                                              :type "arazzo"
                                              :url "pets.json"
                                              :x-ezu-command "pets"}]
                        :workflows []})
                (values (doto (collect [k v (pairs config)] k v)
                          (tset :arazzo {:exo {:file (.. dir "/index.json")}}))
                        dir)))

            (fn exo [args ?routes]
              (let [(cfg dir) (exo-config)
                    r (with-config cfg #(ezu-run args ?routes "/usr/bin/exo"))]
                (os.execute (.. "rm -rf '" dir "'"))
                r))

            (local routes
                   {"GET https://api.test/pets/7" (respond 200 {:name "Rex"})})
            (it "runs a workflow by its words, in a mounted document"
                (fn []
                  (let [r (exo ["pets" "pet" "get" "7" "--output=yaml"] routes)]
                    (assert.are.equal 0 r.code r.err)
                    (assert.are.equal "name: Rex" r.out))
                  (let [r (exo ["pets" "fetchPet" "id=7" "--output=yaml"]
                               routes)]
                    (assert.are.equal 0 r.code r.err)
                    (assert.are.equal "name: Rex" r.out))))
            (it "lists the commands of a group"
                (fn []
                  (assert.are.equal "pets  Pet commands" (. (exo []) :out))
                  (assert.are.equal "pet  get" (. (exo ["pets"]) :out))
                  (assert.are.equal "get  Fetch a pet"
                                    (. (exo ["pets" "pet"]) :out))))
            (it "says which word names nothing"
                (fn []
                  (let [r (exo ["pets" "pett" "get"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "no command 'pett' in exo pets; did you mean pet?"
                                                  1 true)
                                      r.err))))
            (it "shows a workflow's help with its command line"
                (fn []
                  (let [r (exo ["pets" "pet" "get" "--help"])]
                    (assert.are.equal 0 r.code r.err)
                    (assert.is_truthy (r.out:find "Usage: exo pets pet get <id> [name=value ...]"
                                                  1 true)
                                      r.out))))
            (it "completes words, then inputs"
                (fn []
                  (assert.are.equal "pets"
                                    (. (exo ["__complete" "exo p"]) :out))
                  (assert.are.equal "pet"
                                    (. (exo ["__complete" "exo pets "]) :out))
                  (assert.are.equal "get"
                                    (. (exo ["__complete" "exo pets pet "])
                                       :out))
                  (assert.are.equal "id="
                                    (. (exo ["__complete" "exo pets pet get i"])
                                       :out))))
            (it "checks the documents it mounts"
                (fn []
                  (let [r (exo ["--check"])]
                    (assert.are.equal 0 r.code (.. r.out r.err))
                    (assert.are.equal "✓ 2 documents, 1 workflow, 1 step: nothing wrong found"
                                      r.out))))))

(describe "workflow sources fetched from a URL"
          (fn []
            (it "come from the spec cache, until --reload"
                (fn []
                  (let [json (require :ezu.json)
                        spec (with-open [f (io.open "test/fixtures/cli-api.json")]
                               (f:read :*a))
                        ;; a URL of its own: the cache outlives each test
                        url (.. "https://specs.test/" (os.time)
                                (math.random 1000000) "/api.json")
                        flow (with-open [f (io.open "test/fixtures/cli-flow.arazzo.json")]
                               (json.decode (f:read :*a)))
                        file (.. (os.tmpname) ".json")
                        ;; fresh for each run: a run may change the responses
                        routes #{(.. "GET " url) (respond 200
                                                          (json.decode spec))
                                 "GET https://api.test/pets/7" (respond 200
                                                                        {:name "Rex"})}
                        fetches #(accumulate [n 0 _ r (ipairs $.requests)]
                                   (if (= r.url url) (+ n 1) n))]
                    (set (. flow :sourceDescriptions 1 :url) url)
                    (with-open [f (io.open file :w)]
                      (f:write (json.encode flow)))
                    (let [first (ezu-run ["az" file "fetchPet" "id=7"] (routes))
                          second (ezu-run ["az" file "fetchPet" "id=7"]
                                          (routes))
                          reloaded (ezu-run ["az"
                                             file
                                             "fetchPet"
                                             "id=7"
                                             "--reload"]
                                            (routes))]
                      (os.remove file)
                      (assert.are.equal 0 first.code first.err)
                      (assert.are.equal 1 (fetches first))
                      (assert.are.equal 0 second.code second.err)
                      (assert.are.equal 0 (fetches second))
                      (assert.are.equal 0 reloaded.code reloaded.err)
                      (assert.are.equal 1 (fetches reloaded))))))))

(describe "confirming a workflow"
          (fn []
            (local json (require :ezu.json))

            (fn confirm-file []
              (let [flow (with-open [f (io.open "test/fixtures/cli-flow.arazzo.json")]
                           (json.decode (f:read :*a)))
                    file (.. (os.tmpname) ".json")]
                (set (. flow :sourceDescriptions 1 :url)
                     (.. (os.getenv "PWD") "/test/fixtures/cli-api.json"))
                (set (. flow :workflows 1 :x-ezu-confirm)
                     "Fetch pet {$inputs.id}?")
                (with-open [f (io.open file :w)]
                  (f:write (json.encode flow)))
                file))

            (local routes
                   {"GET https://api.test/pets/7" (respond 200 {:name "Rex"})})

            (fn run [args ?answer]
              (let [file (confirm-file)
                    asked []
                    r (with-config (doto (collect [k v (pairs config)] k v)
                                     (tset :arazzo {:c {:file file}}))
                        #(ezu-run (doto ["az" "c" "fetchPet" "id=7"]
                                    (#(each [_ a (ipairs args)]
                                        (table.insert $ a))))
                                  routes nil
                                  (when ?answer
                                    {:ask (fn [question]
                                            (table.insert asked question)
                                            ?answer)})))]
                (os.remove file)
                (values r asked)))

            (it "asks first, and goes ahead on yes only"
                (fn []
                  (let [(yes asked) (run [] "y")
                        (no) (run [] "n")]
                    (assert.are.same ["Fetch pet 7? [y/N] "] asked)
                    (assert.are.equal 0 yes.code yes.err)
                    (assert.are.equal 1 (length yes.requests))
                    (assert.are.equal 1 no.code)
                    (assert.are.equal 0 (length no.requests))
                    (assert.is_truthy (no.err:find "not confirmed" 1 true)
                                      no.err))))
            (it "says in the workflow's help that it asks first"
                (fn []
                  (let [(r) (run ["--help"])]
                    (assert.are.equal 0 r.code r.err)
                    (assert.is_truthy (r.out:find "Asks first: Fetch pet {$inputs.id}? (--yes answers yes)"
                                                  1 true)
                                      r.out))))
            (it "goes ahead with --yes, and refuses without anyone to ask"
                (fn []
                  (let [(yes asked) (run ["--yes"] "n")
                        (alone) (run [])]
                    (assert.are.equal 0 yes.code yes.err)
                    (assert.are.same [] asked)
                    (assert.are.equal 1 alone.code)
                    (assert.are.equal 0 (length alone.requests))
                    (assert.is_truthy (alone.err:find "Fetch pet 7? Nobody to ask: add --yes to go ahead"
                                                      1 true)
                                      alone.err))))))

(describe "settings in the configuration"
          (fn []
            (local json (require :ezu.json))
            (local timed
                   {"GET https://api.test/pets/7" (doto (respond 200
                                                                 {:name "Rex"})
                                                    (tset :timings
                                                          {:namelookup 0.001
                                                           :connect 0.002
                                                           :appconnect 0.003
                                                           :pretransfer 0.003
                                                           :starttransfer 0.01
                                                           :total 0.011}))})
            (it "timing, at the top level or in a profile, which wins"
                (fn []
                  (let [top (with-config {:timing true}
                              #(ezu-run ["http"
                                         "GET"
                                         "https://api.test/pets/7"]
                                        timed))
                        off (with-config {:timing true
                                          :profiles {:t {:base-url "https://api.test"
                                                         :timing false}}}
                              #(ezu-run ["http" "GET" "/pets/7" "--profile=t"]
                                        timed))]
                    (assert.is_truthy (top.err:find "total 11ms" 1 true)
                                      top.err)
                    (assert.are.equal "" off.err))))
            (it "no-paginate in a profile"
                (fn []
                  (let [r (with-config {:profiles {:t {:base-url "https://h.test"
                                                       :no-paginate true}}}
                            #(ezu-run ["http" "/list" "--profile=t"]
                                      {"GET https://h.test/list" (respond 200
                                                                          [1]
                                                                          {:content-type "application/json"
                                                                           :link "<https://h.test/list?page=2>; rel=\"next\""})
                                       "GET https://h.test/list?page=2" (respond 200
                                                                                 [2])}))]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "[1]" (r.out:gsub "%s" "")))))
            (it "check-response in a profile"
                (fn []
                  (let [file (.. (os.tmpname) ".json")]
                    (with-open [f (io.open file :w)]
                      (f:write (json.encode checked-api)))
                    (let [r (with-config {:profiles {:c {:schema file
                                                         :check-response true}}}
                              #(ezu-run ["op" "c" "get-pet" "7"]
                                        {"GET https://api.test/pets/7" (respond 200
                                                                                {:id "7"})}))]
                      (os.remove file)
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find "response.id: expected integer, got string"
                                                    1 true)
                                        r.err)))))
            (it "max-gotos on a workflow document"
                (fn []
                  (let [flow (with-open [f (io.open "test/fixtures/cli-flow.arazzo.json")]
                               (json.decode (f:read :*a)))
                        file (.. (os.tmpname) ".json")
                        step (. flow :workflows 1 :steps 1)]
                    (set (. flow :sourceDescriptions 1 :url)
                         (.. (os.getenv "PWD") "/test/fixtures/cli-api.json"))
                    (set step.successCriteria
                         [{:condition "$statusCode == 299"}])
                    (set step.onFailure
                         [{:name "again" :type "goto" :stepId "get"}])
                    (with-open [f (io.open file :w)]
                      (f:write (json.encode flow)))
                    (let [r (with-config (doto (collect [k v (pairs config)] k
                                                 v)
                                           (tset :arazzo
                                                 {:loop {:file file
                                                         :max-gotos 2}}))
                              #(ezu-run ["az" "loop" "fetchPet" "id=7"]
                                        {"GET https://api.test/pets/7" (respond 200
                                                                                {:name "Rex"})}))]
                      (os.remove file)
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find "goto loop detected" 1 true)
                                        r.err)
                      (assert.are.equal 3 (length r.requests))))))
            (it "refuses settings of the wrong type"
                (fn []
                  (each [_ [cfg message] (ipairs [[{:timing "yes"}
                                                   "config: timing must be true or false"]
                                                  [{:profiles {:t {:no-paginate 1}}}
                                                   "config: profile t: no-paginate must be true or false"]
                                                  [{:arazzo {:f {:file "x"
                                                                 :max-gotos "9"}}}
                                                   "config: arazzo f: max-gotos must be a positive integer"]])]
                    (let [r (with-config cfg
                              #(ezu-run ["--version"]))]
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find message 1 true) r.err)))))))

(describe "--check-response"
          (fn []
            (it "says nothing of a response that matches the spec"
                (fn []
                  (let [r (check-run [] (respond 200 {:id 7 :name "Rex"}))]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "" r.err))))
            (it "lists how a response differs from the spec, prints it, and fails"
                (fn []
                  (let [r (check-run ["--output=yaml"] (respond 200 {:id "7"}))]
                    (assert.are.equal 1 r.code)
                    (assert.are.equal "id: \"7\"" r.out)
                    (assert.is_truthy (r.err:find "response.id: expected integer, got string"
                                                  1 true)
                                      r.err)
                    (assert.is_truthy (r.err:find "response.name: required" 1
                                                  true)))))
            (it "checks errors against their range, and keeps their exit code"
                (fn []
                  (let [r (check-run [] (respond 404 {:error "nope"}))]
                    (assert.are.equal 4 r.code)
                    (assert.is_truthy (r.err:find "response.message: required"
                                                  1 true)
                                      r.err))))
            (it "says when a status or a content type isn't in the spec"
                (fn []
                  (let [r (check-run [] (respond 204 nil {}))]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "status 204 is not among the responses getPet declares"
                                                  1 true)
                                      r.err))
                  (let [r (check-run []
                                     (respond 200 {:id 7 :name "Rex"}
                                              {:content-type "text/plain"}))]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "content type text/plain is not one getPet declares for 200 (application/json)"
                                                  1 true)
                                      r.err))))))

(describe "auth plugins"
          (fn []
            (it "sign each request of a profile whose auth a plugin provides"
                (fn []
                  (let [path (.. (os.tmpname) ".fnl")]
                    (with-open [f (io.open path :w)]
                      (f:write "{:auth {:demo (fn [req params ezu] {:headers {:authorization (.. \"Demo \" (ezu.hex (ezu.sha256 req.url)) \" \" params.key)}})}}"))
                    (os.execute (.. "chmod 600 " path))
                    (let [r (with-config {:plugins [path]
                                          :profiles {:p {:base-url "https://api.test"
                                                         :auth {:name "demo"
                                                                :params {:key "k1"}}}}}
                              #(ezu-run ["http" "/pets/7" "--profile=p"]
                                        {"GET https://api.test/pets/7" (respond 200
                                                                                {})}))
                          digest (require :ezu.digest)]
                      (os.remove path)
                      (assert.are.equal 0 r.code)
                      (assert.are.equal (.. "Demo "
                                            (digest.hex (digest.sha256 "https://api.test/pets/7"))
                                            " k1")
                                        (. r.requests 1 :headers :authorization))))))))

(describe "ezu http"
          (fn []
            (it "says how long each exchange took with --timing"
                (fn []
                  (let [r (ezu-run ["http"
                                    "GET"
                                    "https://api.test/pets/7"
                                    "--timing"]
                                   {"GET https://api.test/pets/7" (doto (respond 200
                                                                                 {:name "Rex"})
                                                                    (tset :timings
                                                                          {:namelookup 0.001
                                                                           :connect 0.002
                                                                           :appconnect 0.003
                                                                           :pretransfer 0.003
                                                                           :starttransfer 0.01
                                                                           :total 0.011}))})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "GET https://api.test/pets/7  200  dns 1ms · tcp 1ms · tls 1ms · server 7ms · download 1ms · total 11ms\n"
                                      r.err))))
            (it "sends a request with the profile's headers and auth"
                (fn []
                  (let [r (ezu-run ["http"
                                    "GET"
                                    "https://api.test/pets/7"
                                    "--profile=p"
                                    "--no-color"]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {:name "Rex"})})]
                    (assert.are.equal 0 r.code)
                    (assert.is_truthy (r.out:find "\"name\": \"Rex\"" 1 true))
                    (assert.are.equal "Bearer t0k"
                                      (. r.requests 1 :headers :authorization))
                    (assert.are.equal "o1" (. r.requests 1 :headers :x-org)))))
            (it "defaults to GET and resolves paths against the profile's API"
                (fn []
                  (let [r (ezu-run ["http" "/pets/7" "--profile=p"]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {})})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "GET" (. r.requests 1 :method))
                    (assert.are.equal "https://api.test/pets/7"
                                      (. r.requests 1 :url)))))
            (it "resolves paths against --base-url"
                (fn []
                  (let [r (ezu-run ["http"
                                    "delete"
                                    "pets/7"
                                    "--base-url=https://h.test/v1/"]
                                   {"DELETE https://h.test/v1/pets/7" (respond 204
                                                                               nil)})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "DELETE" (. r.requests 1 :method)))))
            (it "refuses to send a profile's credentials to another origin"
                (fn []
                  (let [r (ezu-run ["http"
                                    "GET"
                                    "https://evil.test/pets"
                                    "--profile=p"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "https://api.test" 1 true))
                    (assert.are.equal 0 (length r.requests)))))
            (it "sends no credentials without a profile"
                (fn []
                  (let [r (ezu-run ["http" "https://other.test/x"]
                                   {"GET https://other.test/x" (respond 200 {})})]
                    (assert.are.equal 0 r.code)
                    (assert.is_nil (. r.requests 1 :headers :authorization)))))
            (it "needs a base URL for a path"
                (fn []
                  (let [r (ezu-run ["http" "GET" "/pets"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "--profile or --base-url" 1
                                                  true)))))
            (it "sends a JSON body as given"
                (fn []
                  (let [r (ezu-run ["http"
                                    "POST"
                                    "https://h.test/pets"
                                    "-d"
                                    "{\"size\": 1.50}"]
                                   {"POST https://h.test/pets" (respond 201 {})})
                        req (. r.requests 1)]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "{\"size\": 1.50}" req.body)
                    (assert.are.equal "application/json"
                                      (. req.headers :content-type)))))
            (it "builds a JSON body from fields"
                (fn []
                  (let [r (ezu-run ["http"
                                    "POST"
                                    "https://h.test/pets"
                                    "-d"
                                    "name: Rex"
                                    "--b.size=2"
                                    "--b.tag.color=red"]
                                   {"POST https://h.test/pets" (respond 201 {})})
                        req (. r.requests 1)]
                    (assert.are.equal 0 r.code)
                    (assert.are.same {:name "Rex" :size 2 :tag {:color "red"}}
                                     req.body)
                    (assert.are.equal "application/json"
                                      (. req.headers :content-type)))))
            (it "sends other bodies as-is, with the given content type"
                (fn []
                  (let [r (ezu-run ["http"
                                    "PUT"
                                    "https://h.test/note"
                                    "-d"
                                    "hello"
                                    "--h.Content-Type=text/plain"]
                                   {"PUT https://h.test/note" (respond 204 nil)})
                        req (. r.requests 1)]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "hello" req.body)
                    (assert.are.equal "text/plain"
                                      (. req.headers :content-type)))))
            (it "adds query parameters to the URL's own"
                (fn []
                  (let [r (ezu-run ["http"
                                    "https://h.test/pets?limit=1"
                                    "--q.status=sold"]
                                   {"GET https://h.test/pets?limit=1&status=sold" (respond 200
                                                                                           [])})]
                    (assert.are.equal 0 r.code))))
            (it "prints the request with redacted credentials for --dry-run"
                (fn []
                  (let [r (ezu-run ["http"
                                    "GET"
                                    "/pets"
                                    "--profile=p"
                                    "--dry-run"])]
                    (assert.are.equal 0 r.code)
                    (assert.is_truthy (r.out:find "GET https://api.test/pets" 1
                                                  true))
                    (assert.is_nil (r.out:find "t0k" 1 true))
                    (assert.are.equal 0 (length r.requests)))))
            (it "maps HTTP errors to exit codes"
                (fn []
                  (assert.are.equal 4
                                    (. (ezu-run ["http" "https://h.test/none"])
                                       :code))))
            (it "refuses options that need a spec, and extra arguments"
                (fn []
                  (let [r (ezu-run ["http" "GET" "https://h.test/" "--list"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "doesn't apply to http" 1
                                                  true)))
                  (let [r (ezu-run ["http" "GET" "https://h.test/" "extra"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "Usage: ezu http" 1 true)))
                  (let [r (ezu-run ["http"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "Usage: ezu http" 1 true)))))
            (it "checks --select before sending"
                (fn []
                  (let [r (ezu-run ["http"
                                    "POST"
                                    "https://h.test/x"
                                    "--select=.a[?b=1]"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "invalid filter" 1 true))
                    (assert.are.equal 0 (length r.requests)))))
            (it "prints usage for --help without sending"
                (fn []
                  (let [r (ezu-run ["http" "GET" "https://h.test/" "--help"])]
                    (assert.are.equal 0 r.code)
                    (assert.is_truthy (r.out:find "Options (http):" 1 true))
                    (assert.are.equal 0 (length r.requests)))))
            (it "needs a URL after a method, and takes only valid methods"
                (fn []
                  (let [r (ezu-run ["http" "DELETE" "--profile=p"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "Usage: ezu http" 1 true))
                    (assert.are.equal 0 (length r.requests)))
                  (let [r (ezu-run ["http"
                                    "/a"
                                    "/b"
                                    "--base-url=https://h.test"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "invalid HTTP method: /a" 1
                                                  true))
                    (assert.are.equal 0 (length r.requests)))))
            (it "fails on a profile it doesn't know"
                (fn []
                  (let [r (ezu-run ["http" "/x" "--profile=nope"])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "Profile not found: nope" 1
                                                  true)))))))

(local mcp-meta
       {"io.modelcontextprotocol/protocolVersion" "2026-07-28"
        "io.modelcontextprotocol/clientCapabilities" {}})

(fn mcp-run [args messages ?routes]
  "Run ezu mcp in-process, reading messages (tables) as its input; returns
{:code :responses :out :err :requests}."
  (let [json (require :ezu.json)
        (transport requests) (routes-transport (or ?routes {}))
        lines (icollect [_ m (ipairs messages)]
                (json.encode m))
        responses []
        out []
        err []
        real-print _G.print
        real-stderr io.stderr]
    (var i 0)
    (set _G.print
         (fn [...]
           (table.insert out (table.concat [...] "\t"))))
    (set io.stderr {:write (fn [_ s] (table.insert err s))})
    (let [(ok code) (pcall cli.run args
                           {: transport
                            :config current-config
                            :read-line (fn []
                                         (set i (+ i 1))
                                         (. lines i))
                            :write-line #(table.insert responses
                                                       (json.decode $ true))})]
      (set _G.print real-print)
      (set io.stderr real-stderr)
      (assert ok code)
      {: code
       : responses
       :out (table.concat out "\n")
       :err (table.concat err)
       : requests})))

(fn tool-names [r]
  (icollect [_ t (ipairs (. r.responses 1 :result :tools))]
    t.name))

(fn call [id name arguments]
  {:jsonrpc "2.0"
   : id
   :method "tools/call"
   :params {:_meta mcp-meta : name : arguments}})

(local list-tools {:jsonrpc "2.0"
                   :id 1
                   :method "tools/list"
                   :params {:_meta mcp-meta}})

(describe "ezu mcp"
          (fn []
            (it "offers the read-only operations as tools"
                (fn []
                  (let [r (mcp-run ["mcp" "p"] [list-tools])]
                    (assert.are.equal 0 r.code)
                    (assert.are.same ["get-pet" "get-secure" "list-pets"]
                                     (tool-names r))
                    (assert.are.equal "" r.out)
                    ;; the profile's auth supplies Authorization
                    (assert.is_nil (. r.responses 1 :result :tools 2
                                      :inputSchema :properties :Authorization)))))
            (it "offers every operation with --allow-writes"
                (fn []
                  (assert.are.same ["add-pet"
                                    "get-pet"
                                    "get-secure"
                                    "list-pets"]
                                   (tool-names (mcp-run ["mcp"
                                                         "p"
                                                         "--allow-writes"]
                                                        [list-tools])))))
            (it "offers the operations the profile lists"
                (fn []
                  (with-config {:profiles {:m {:schema "test/fixtures/cli-api.json"
                                               :mcp {:operations ["add-pet"
                                                                  "list-pets"]}}}}
                    #(assert.are.same ["add-pet" "list-pets"]
                                      (tool-names (mcp-run ["mcp" "m"]
                                                           [list-tools]))))
                  (with-config {:profiles {:m {:schema "test/fixtures/cli-api.json"
                                               :mcp {:operations ["nope"]}}}}
                    #(let [r (mcp-run ["mcp" "m"] [list-tools])]
                       (assert.are.equal 1 r.code)
                       (assert.is_truthy (r.err:find "unknown operation in mcp.operations: nope"
                                                     1 true))))
                  (with-config {:profiles {:m {:schema "test/fixtures/cli-api.json"
                                               :mcp {:operations "add-pet"}}}}
                    #(let [r (mcp-run ["mcp" "m"] [list-tools])]
                       (assert.are.equal 1 r.code)
                       (assert.is_truthy (r.err:find "mcp.operations must be a list of operation names"
                                                     1 true))))))
            (it "takes * patterns in mcp.operations"
                (fn []
                  (with-config {:profiles {:m {:schema "test/fixtures/cli-api.json"
                                               :mcp {:operations ["get-*"
                                                                  "*-pets"
                                                                  "list-pets"]}}}}
                    #(assert.are.same ["get-pet" "get-secure" "list-pets"]
                                      (tool-names (mcp-run ["mcp" "m"]
                                                           [list-tools]))))
                  (with-config {:profiles {:m {:schema "test/fixtures/cli-api.json"
                                               :mcp {:operations ["remove-*"]}}}}
                    #(let [r (mcp-run ["mcp" "m"] [list-tools])]
                       (assert.are.equal 1 r.code)
                       (assert.is_truthy (r.err:find "mcp.operations: remove-* matches no operation"
                                                     1 true))))))
            (it "calls the API with the profile's auth"
                (fn []
                  (let [r (mcp-run ["mcp" "p"] [(call 2 "get-pet" {:id "7"})]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {:name "Rex"})})
                        result (. r.responses 1 :result)]
                    (assert.are.equal "Bearer t0k"
                                      (. r.requests 1 :headers :authorization))
                    (assert.are.equal :complete result.resultType)
                    (assert.is_false result.isError)
                    (assert.are.same [{:type :text :text "{\"name\":\"Rex\"}"}]
                                     result.content))))
            (it "reports HTTP errors as tool errors"
                (fn []
                  (let [r (mcp-run ["mcp" "p" "--retry=0"]
                                   [(call 2 "get-pet" {:id "1"})]
                                   {"GET https://api.test/pets/1" (respond 404
                                                                           {:error "no pet"})})
                        result (. r.responses 1 :result)]
                    (assert.is_true result.isError)
                    (assert.are.equal "HTTP 404\n{\"error\":\"no pet\"}"
                                      (. result.content 1 :text)))))
            (it "checks arguments before sending"
                (fn []
                  (let [r (mcp-run ["mcp" "p" "--allow-writes"]
                                   [(call 2 "add-pet" {:body {}})
                                    (call 3 "get-pet" {:id "1" :nope 2})])]
                    (assert.are.equal 0 (length r.requests))
                    (assert.is_true (. r.responses 1 :result :isError))
                    (assert.is_truthy (: (. r.responses 1 :result :content 1
                                            :text)
                                         :find "body.name: required" 1 true))
                    (assert.is_true (. r.responses 2 :result :isError))
                    (assert.is_truthy (: (. r.responses 2 :result :content 1
                                            :text)
                                         :find "unknown argument: nope" 1 true)))))
            (it "won't call an operation it doesn't offer"
                (fn []
                  (let [r (mcp-run ["mcp" "p"]
                                   [(call 2 "add-pet" {:body {:name "x"}})])]
                    (assert.are.equal -32602 (. r.responses 1 :error :code))
                    (assert.are.equal 0 (length r.requests)))))
            (it "warns when it offers more tools than clients handle well"
                (fn []
                  (let [json (require :ezu.json)
                        spec (.. (os.tmpname) ".json")
                        paths (collect [_ i (ipairs (fcollect [i 1 101] i))]
                                (.. "/r" i)
                                {:get {:operationId (.. "get" i)}})]
                    (with-open [f (io.open spec :w)]
                      (f:write (json.encode {:openapi "3.1.0"
                                             :info {:title "Big"}
                                             :servers [{:url "https://h.test"}]
                                             : paths})))
                    (let [r (mcp-run ["mcp" spec] [])]
                      (os.remove spec)
                      (assert.are.equal 0 r.code)
                      (assert.is_truthy (r.err:find "warning: 101 tools" 1 true))
                      (assert.is_truthy (r.err:find "mcp.operations" 1 true))))))
            (it "offers Arazzo workflows as tools"
                (fn []
                  (assert.are.same ["get-pet"
                                    "get-secure"
                                    "list-pets"
                                    "workflow.fetchPet"]
                                   (tool-names (mcp-run ["mcp"
                                                         "p"
                                                         "--arazzo=flows"]
                                                        [list-tools])))
                  (assert.are.same ["workflow.fetchPet"]
                                   (tool-names (mcp-run ["mcp"
                                                         "--arazzo=flows"]
                                                        [list-tools])))))
            (it "runs a workflow and returns its outputs"
                (fn []
                  (let [r (mcp-run ["mcp" "--arazzo=flows"]
                                   [(call 2 "workflow.fetchPet" {:id "7"})
                                    (call 3 "workflow.fetchPet" {:id 7})
                                    (call 4 "workflow.fetchPet" {:id "1"})]
                                   {"GET https://api.test/pets/7" (respond 200
                                                                           {:name "Rex"})})]
                    (assert.are.same {:isError false
                                      :content [{:type :text
                                                 :text "{\"name\":\"Rex\"}"}]}
                                     (doto (. r.responses 1 :result)
                                       (tset :resultType nil)
                                       (tset :_meta nil)))
                    ;; inputs are checked against the workflow's schema
                    (assert.is_true (. r.responses 2 :result :isError))
                    (assert.is_truthy (: (. r.responses 2 :result :content 1
                                            :text)
                                         :find "inputs.id" 1 true))
                    (assert.are.equal 2 (length r.requests))
                    ;; a failing workflow is a tool error
                    (assert.is_true (. r.responses 3 :result :isError)))))
            (it "checks body and parameter values, and hides ezu's internals"
                (fn []
                  (let [r (mcp-run ["mcp" "p" "--allow-writes" "--retry=0"]
                                   [(call 2 "add-pet" {:body "Rex"})
                                    (call 3 "list-pets" {:status "lost"})
                                    (call 4 "get-pet" {})
                                    (call 5 "get-pet" {:id "1"})]
                                   {"GET https://api.test/pets/1" #(error "connection refused")})
                        text #(. r.responses $ :result :content 1 :text)]
                    (assert.are.equal 1 (length r.requests))
                    (each [i _ (ipairs r.responses)]
                      (assert.is_true (. r.responses i :result :isError)))
                    (assert.is_truthy (: (text 1) :find "body: expected object"
                                         1 true))
                    (assert.is_truthy (: (text 2) :find "status:" 1 true))
                    (assert.is_truthy (: (text 3) :find
                                         "missing required argument: id" 1 true))
                    (assert.is_nil (: (text 4) :find "%.lua:"))
                    (assert.is_truthy (: (text 4) :find "connection refused" 1
                                         true)))))
            (it "takes only an object as a workflow's arguments"
                (fn []
                  (let [r (mcp-run ["mcp" "--arazzo=flows"]
                                   [(call 2 "workflow.fetchPet" [1])
                                    (call 3 "workflow.fetchPet" "x")])]
                    (assert.are.equal 0 (length r.requests))
                    (each [i _ (ipairs r.responses)]
                      (assert.is_true (. r.responses i :result :isError))
                      (assert.are.equal "arguments must be an object"
                                        (. r.responses i :result :content 1
                                           :text))))))
            (it "refuses two workflows that make the same tool name"
                (fn []
                  (let [json (require :ezu.json)
                        file (.. (os.tmpname) ".json")]
                    (with-open [f (io.open file :w)]
                      (f:write (json.encode {:arazzo "1.0.0"
                                             :info {:title "t" :version "1"}
                                             :sourceDescriptions [{:name "api"
                                                                   :url "test/fixtures/cli-api.json"}]
                                             :workflows [{:workflowId "get it"
                                                          :steps []}
                                                         {:workflowId "get_it"
                                                          :steps []}]})))
                    (let [r (mcp-run ["mcp" (.. "--arazzo=" file)] [list-tools])]
                      (os.remove file)
                      (assert.are.equal 1 r.code)
                      (assert.is_truthy (r.err:find "workflow.get_it" 1 true))))))
            (it "shows its usage"
                (fn []
                  (let [r (mcp-run ["mcp"] [])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "Usage: ezu mcp" 1 true)))
                  (let [r (mcp-run ["mcp" "p" "extra"] [])]
                    (assert.are.equal 1 r.code)
                    (assert.is_truthy (r.err:find "Usage: ezu mcp" 1 true)))
                  (let [r (mcp-run ["mcp" "p" "--dry-run"] [])]
                    (assert.are.equal 1 r.code))))))

(fn fixture-spec []
  (let [json (require :ezu.json)]
    (with-open [f (io.open "test/fixtures/cli-api.json")]
      (json.decode (f:read :*a)))))

(fn discovering [base auth]
  {:profiles {:d {:base-url base : auth}}})

(describe "spec discovery"
          (fn []
            (it "follows the base URL's Link rel=service-desc"
                (fn []
                  (with-config (discovering "https://d1.test/v1")
                    #(let [r (ezu-run ["op" "d" "list-pets"]
                                      {"GET https://d1.test/v1" (respond 200 {}
                                                                         {:link "</specs/api.json>; rel=\"service-desc\""})
                                       "GET https://d1.test/specs/api.json" (respond 200
                                                                                     (fixture-spec))
                                       "GET https://d1.test/v1/pets" (respond 200
                                                                              [])})]
                       (assert.are.equal 0 r.code)
                       (assert.are.equal "https://d1.test/v1/pets"
                                         (. r.requests (length r.requests) :url))))))
            (it "tries openapi.json and openapi.yaml under the base URL"
                (fn []
                  (with-config (discovering "https://d2.test/v1/")
                    #(let [r (ezu-run ["op" "d" "--list"]
                                      {"GET https://d2.test/v1/openapi.yaml" (respond 200
                                                                                      (fixture-spec))})]
                       (assert.are.equal 0 r.code)
                       (assert.is_truthy (r.out:find "list-pets" 1 true))))))
            (it "takes the base URL's own body when it is the spec"
                (fn []
                  (with-config (discovering "https://d3.test")
                    #(let [r (ezu-run ["op" "d" "--list"]
                                      {"GET https://d3.test" (respond 200
                                                                      (fixture-spec))})]
                       (assert.are.equal 0 r.code)
                       (assert.is_truthy (r.out:find "list-pets" 1 true))))))
            (it "follows links to the base URL's origin only"
                (fn []
                  (with-config (discovering "https://d4.test")
                    #(let [r (ezu-run ["op" "d" "--list"]
                                      {"GET https://d4.test" (respond 200 {}
                                                                      {:link "<https://evil.test/spec.json>; rel=\"service-desc\""})
                                       "GET https://evil.test/spec.json" (respond 200
                                                                                  (fixture-spec))})]
                       (assert.are.equal 1 r.code)
                       (each [_ req (ipairs r.requests)]
                         (assert.is_nil (req.url:find "evil.test" 1 true)))))))
            (it "asks for credentials when the base URL wants them"
                (fn []
                  (with-config (discovering "https://d5.test"
                                            {:name "bearer"
                                             :params {:token "t0k"}})
                    #(let [r (ezu-run ["op" "d" "--list"]
                                      {"GET https://d5.test" (fn [req]
                                                               (if (= (?. req
                                                                          :headers
                                                                          :authorization)
                                                                      "Bearer t0k")
                                                                   (respond 200
                                                                            {}
                                                                            {:link "</openapi>; rel=\"service-desc\""})
                                                                   (respond 401
                                                                            {})))
                                       "GET https://d5.test/openapi" (respond 200
                                                                              (fixture-spec))})]
                       (assert.are.equal 0 r.code)))))
            (it "remembers where it found the spec"
                (fn []
                  (with-config (discovering "https://d6.test")
                    #(let [routes {"GET https://d6.test/openapi.json" (respond 200
                                                                               (fixture-spec))}
                           first (ezu-run ["op" "d" "--list"] routes)
                           again (ezu-run ["op" "d" "--list"] routes)]
                       (assert.are.equal 0 first.code)
                       (assert.are.equal 0 again.code)
                       (assert.are.equal 0 (length again.requests))))))
            (it "says where it looked when it finds nothing"
                (fn []
                  (with-config (discovering "https://d7.test/api")
                    #(let [r (ezu-run ["op" "d" "--list"])]
                       (assert.are.equal 1 r.code)
                       (assert.is_truthy (r.err:find "no OpenAPI description found for https://d7.test/api"
                                                     1 true))
                       (assert.is_truthy (r.err:find "\"schema\"" 1 true))))))))

(describe "streamed responses"
          (fn []
            (it "prints server-sent events as they come"
                (fn []
                  (let [r (ezu-run ["http" "https://h.test/events"]
                                   {"GET https://h.test/events" (respond-text 200
                                                                              "text/event-stream"
                                                                              ["data: {\"n\":1}\n"
                                                                               "\nevent: x\r\ndata: {\"n\":2}\r\n\r\n"
                                                                               ": keep-alive\n\n"
                                                                               "data: plain\ndata: text\n\n"
                                                                               "data: \"s\"\n\n"])})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "{\"n\":1}\n{\"n\":2}\nplain\ntext\n\"s\""
                                      r.out)
                    (assert.are.equal "" r.err))))
            (it "selects in each record"
                (fn []
                  (let [r (ezu-run ["http"
                                    "https://h.test/events"
                                    "--select=.n"]
                                   {"GET https://h.test/events" (respond-text 200
                                                                              "text/event-stream"
                                                                              ["data: {\"n\":1}\n\n"
                                                                               "data: {\"m\":2}\n\n"
                                                                               "data: {\"n\":3}\n\n"])})]
                    (assert.are.equal "1\n3" r.out))))
            (it "prints JSON Lines records as they come"
                (fn []
                  (let [r (ezu-run ["http" "https://h.test/lines"]
                                   {"GET https://h.test/lines" (respond-text 200
                                                                             "application/x-ndjson"
                                                                             ["{\"a\":1}\n{\"a\""
                                                                              ":2}\n\n{\"a\":3}"])})]
                    (assert.are.equal "{\"a\":1}\n{\"a\":2}\n{\"a\":3}" r.out))))
            (it "writes any body as it comes with --output=raw"
                (fn []
                  (let [r (ezu-run ["http"
                                    "https://h.test/file"
                                    "--output=raw"]
                                   {"GET https://h.test/file" (respond-text 200
                                                                            "application/octet-stream"
                                                                            ["ab"
                                                                             "\0c"
                                                                             "d"])})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "ab\0cd" r.out))))
            (it "still merges the pages of a JSON array with --output=raw"
                (fn []
                  (let [r (ezu-run ["http"
                                    "https://h.test/list"
                                    "--output=raw"]
                                   {"GET https://h.test/list" (respond 200 [1]
                                                                       {:content-type "application/json"
                                                                        :link "<https://h.test/list?page=2>; rel=\"next\""})
                                    "GET https://h.test/list?page=2" (respond 200
                                                                              [2])})]
                    (assert.are.equal 0 r.code)
                    (assert.are.equal "[1,2]" r.out))))
            (it "leaves error responses to the usual reporting"
                (fn []
                  (let [r (ezu-run ["http" "https://h.test/events" "--retry=0"]
                                   {"GET https://h.test/events" (respond-text 503
                                                                              "text/event-stream"
                                                                              ["data: down\n\n"])})]
                    (assert.are.equal 5 r.code)
                    (assert.are.equal "" r.out)
                    (assert.is_truthy (r.err:find "HTTP 503" 1 true)))))
            (it "streams the responses of operations too"
                (fn []
                  (let [json (require :ezu.json)
                        spec (.. (os.tmpname) ".json")]
                    (with-open [f (io.open spec :w)]
                      (f:write (json.encode {:openapi "3.1.0"
                                             :info {:title "s" :version "1"}
                                             :servers [{:url "https://h.test"}]
                                             :paths {"/events" {:get {:operationId "events"
                                                                      :responses {:200 {:description "ok"
                                                                                        :content {:text/event-stream {}}}}}}}})))
                    (let [r (ezu-run ["op" spec "events"]
                                     {"GET https://h.test/events" (respond-text 200
                                                                                "text/event-stream"
                                                                                ["data: 1\n\n"])})]
                      (os.remove spec)
                      (assert.are.equal 0 r.code)
                      (assert.are.equal "1" r.out)))))))

(describe "spec discovery, from review"
          (fn []
            (it "redacts the base URL and says what each place answered"
                (fn []
                  (with-config (discovering "https://bob:hunter2@d8.test/q?api_key=topsecret")
                    #(let [r (ezu-run ["op" "d" "--list"]
                                      {"GET https://bob:hunter2@d8.test/q/openapi.json?api_key=topsecret" (respond 403
                                                                                                                   {})})]
                       (assert.are.equal 1 r.code)
                       (assert.is_nil (r.err:find "hunter2" 1 true))
                       (assert.is_nil (r.err:find "topsecret" 1 true))
                       (assert.is_truthy (r.err:find "HTTP 403" 1 true))))))
            (it "puts the file name before the base URL's query"
                (fn []
                  (with-config (discovering "https://d9.test/v1?k=1")
                    #(let [r (ezu-run ["op" "d" "--list"]
                                      {"GET https://d9.test/v1/openapi.json?k=1" (respond 200
                                                                                          (fixture-spec))})]
                       (assert.are.equal 0 r.code)))))
            (it "doesn't cache what isn't a spec"
                (fn []
                  (with-config (discovering "https://d10.test/api")
                    #(let [first (ezu-run ["op" "d" "--list"]
                                          {"GET https://d10.test/api/openapi.json" (respond 200
                                                                                            {:error "nothing"})})
                           again (ezu-run ["op" "d" "--list"]
                                          {"GET https://d10.test/api/openapi.json" (respond 200
                                                                                            (fixture-spec))})]
                       (assert.are.equal 1 first.code)
                       (assert.are.equal 0 again.code)))))
            (it "fetches the spec it found once"
                (fn []
                  (with-config (discovering "https://d11.test")
                    #(let [r (ezu-run ["op" "d" "--list" "--reload"]
                                      {"GET https://d11.test/openapi.json" (respond 200
                                                                                    (fixture-spec))})]
                       (assert.are.equal 0 r.code)
                       ;; the base URL's Link header, then the spec
                       (assert.are.equal 2 (length r.requests))))))
            (it "looks again when the spec it remembered is gone"
                (fn []
                  (with-config (discovering "https://d12.test")
                    #(let [first (ezu-run ["op" "d" "--list"]
                                          {"GET https://d12.test/openapi.json" (respond 200
                                                                                        (fixture-spec))})
                           cache (require :ezu.cache)
                           _ (cache.put "https://d12.test/openapi.json" nil)
                           again (ezu-run ["op" "d" "--list"]
                                          {"GET https://d12.test/openapi.yaml" (respond 200
                                                                                        (fixture-spec))})]
                       (assert.are.equal 0 first.code)
                       (assert.are.equal 0 again.code)))))
            (it "also tries the origin's root under a base path"
                (fn []
                  (with-config (discovering "https://d13.test/v2/ops")
                    #(let [r (ezu-run ["op" "d" "--list"]
                                      {"GET https://d13.test/openapi.json" (respond 200
                                                                                    (fixture-spec))})]
                       (assert.are.equal 0 r.code)))))))

(fn closed-stdout-run [args routes]
  "ezu-run with a stdout whose reader went away."
  (set stdout-closed true)
  (let [(ok r) (pcall ezu-run args routes)]
    (set stdout-closed false)
    (assert ok r)
    r))

(describe "streamed responses, from review"
          (fn []
            (it "stops when its reader goes away"
                (fn []
                  (let [pieces (fcollect [i 1 50] (.. "data: " i "\n\n"))
                        sent []
                        r (closed-stdout-run ["http" "https://h.test/events"]
                                             {"GET https://h.test/events" (respond-text 200
                                                                                        "text/event-stream"
                                                                                        pieces)})]
                    (assert.are.equal 141 r.code)
                    (assert.are.equal "" r.err))))
            (it "keeps a CRLF split between pieces together"
                (fn []
                  (let [r (ezu-run ["http" "https://h.test/events"]
                                   {"GET https://h.test/events" (respond-text 200
                                                                              "text/event-stream"
                                                                              ["data: {\"a\":\r"
                                                                               "\ndata: 1}\r"
                                                                               "\n\r\n"])})]
                    (assert.are.equal "{\"a\": 1}" r.out))))
            (it "reads events as the event stream format has them"
                (fn []
                  (let [r (ezu-run ["http" "https://h.test/events"]
                                   {"GET https://h.test/events" (respond-text 200
                                                                              "text/event-stream"
                                                                              ["\239\187\191data: first\n\n"
                                                                               "data\ndata: x\n\n"
                                                                               "data: unfinished"])})]
                    (assert.are.equal "first\n\nx" r.out))))
            (it "prints records as they came, without a selection"
                (fn []
                  (let [r (ezu-run ["http" "https://h.test/lines"]
                                   {"GET https://h.test/lines" (respond-text 200
                                                                             "application/x-ndjson"
                                                                             ["{\"b\":1,\"a\":2.50,\"big\":12345678901234567890}\n"])})]
                    (assert.are.equal "{\"b\":1,\"a\":2.50,\"big\":12345678901234567890}"
                                      r.out))))
            (it "leaves formats that need the whole body to it"
                (fn []
                  (let [routes {"GET https://h.test/lines" (respond-text 200
                                                                         "application/x-ndjson"
                                                                         ["{\"a\":1}\n{\"a\":2}\n"])}]
                    (assert.are.equal "200"
                                      (. (ezu-run ["http"
                                                   "https://h.test/lines"
                                                   "--output=status"]
                                                  routes)
                                         :out))
                    (assert.are.equal "a\n1\n2"
                                      (. (ezu-run ["http"
                                                   "https://h.test/lines"
                                                   "--output=csv"]
                                                  routes)
                                         :out)))))
            (it "streams raw output only for bodies it needn't read"
                (fn []
                  (let [untyped {:status 200
                                 :headers {:link "<https://h.test/u?p=2>; rel=\"next\""}
                                 :raw "[1]"
                                 :body [1]
                                 :pieces ["[1]"]}
                        r (ezu-run ["http" "https://h.test/u" "--output=raw"]
                                   {"GET https://h.test/u" untyped
                                    "GET https://h.test/u?p=2" (respond 200 [2])})]
                    (assert.are.equal "[1,2]" r.out))
                  (let [r (ezu-run ["http"
                                    "https://h.test/y"
                                    "--output=raw"
                                    "--select=.a"]
                                   {"GET https://h.test/y" (respond-text 200
                                                                         "text/plain"
                                                                         ["plain"])})]
                    (assert.are.equal 0 r.code))))
            (it "shows the status and headers before the stream with -v"
                (fn []
                  (let [r (ezu-run ["http" "https://h.test/events" "-v"]
                                   {"GET https://h.test/events" (respond-text 200
                                                                              "text/event-stream"
                                                                              ["data: 1\n\n"])})]
                    (assert.are.equal "1" r.out)
                    (let [(_ n) (r.err:gsub "HTTP 200" "")]
                      (assert.are.equal 1 n)))))))
