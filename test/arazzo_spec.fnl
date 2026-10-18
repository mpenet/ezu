;; ABOUTME: Specs for Arazzo document loading, client resolution and workflow execution.
;; ABOUTME: Run with `make test` (busted, Fennel loader).
(local arazzo (require :ezu.arazzo))

;; ---- helpers ----

(fn make-client [ops]
  "Build a fake ezu client: {operationId → (fn [req] resp)}."
  (collect [id f (pairs ops)]
    (.. "op-" id)
    {:operation-id id
     :method "get"
     :url-for (fn [req] (.. "https://api.test/" id (if req.query "?q" "")))
     :invoke f}))

(fn ok-resp [body ?status]
  {:status (or ?status 200)
   :headers {:content-type "application/json"}
   :body body})

(fn counter []
  (let [n [0]]
    {:inc (fn []
            (tset n 1 (+ (. n 1) 1)))
     :val (fn [] (. n 1))}))

;; ---- load-doc ----

(describe "load-doc"
          (fn []
            (it "loads a JSON file from disk"
                (fn []
                  (let [doc (arazzo.load-doc "test/fixtures/simple.arazzo.json")]
                    (assert.are.equal "1.0.0" doc.arazzo)
                    (assert.is_not_nil doc.workflows))))
            (it "gives up on documents after the timeout"
                (fn []
                  (let [socket (require :socket)
                        srv (assert (socket.bind "127.0.0.1" 0))
                        (_ port) (srv:getsockname)
                        url (.. "http://127.0.0.1:" port)
                        flow (.. (os.tmpname) ".json")
                        t0 (socket.gettime)]
                    (with-open [f (io.open flow :w)]
                      (f:write (.. "{\"arazzo\":\"1.0.0\",\"info\":{},\"workflows\":[{\"workflowId\":\"w\",\"inputs\":{\"$ref\":\""
                                   url "/inputs.json\"},\"steps\":[]}]}")))
                    (let [(ok1) (pcall arazzo.load-doc (.. url "/flow.json")
                                       {:timeout 0.2})
                          (ok2) (pcall arazzo.run flow "w" {}
                                       {:clients {} :timeout 0.2})]
                      (srv:close)
                      (os.remove flow)
                      (assert.is_false ok1)
                      (assert.is_false ok2)
                      (assert.is_true (< (- (socket.gettime) t0) 5))))))))

;; ---- build-clients ----

(describe "build-clients"
          (fn []
            (it "returns empty table when no sourceDescriptions"
                (fn []
                  (let [doc {:arazzo "1.0.0" :info {} :workflows []}
                        clients (arazzo.build-clients doc {})]
                    (assert.are.same {} clients))))
            (it "resolves relative source URLs against the document location"
                (fn []
                  (let [doc {:sourceDescriptions [{:name "pets"
                                                   :type "openapi"
                                                   :url "./petstore.yaml"}]
                             :workflows []}
                        clients (arazzo.build-clients doc {}
                                                      "test/fixtures/flow.arazzo.json")]
                    (assert.is_not_nil (. clients :pets)))))
            (it "rejects a base-url override when several openapi sources exist"
                (fn []
                  (let [doc {:sourceDescriptions [{:name "a"
                                                   :type "openapi"
                                                   :url "./petstore.yaml"}
                                                  {:name "b"
                                                   :type "openapi"
                                                   :url "./petstore.yaml"}]
                             :workflows []}]
                    (assert.has.error #(arazzo.build-clients doc
                                                             {:base-url "https://x"}
                                                             "test/fixtures/flow.arazzo.json")
                                      "base-url override is ambiguous: the document has 2 openapi sources"))))
            (it "gives each source only the server variables it declares"
                (fn []
                  (let [dir (os.tmpname)
                        write (fn [name content]
                                (let [f (io.open (.. dir "-" name) :w)]
                                  (f:write content)
                                  (f:close)))]
                    (write "a.json"
                           "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://{zone}.a.test\",\"variables\":{\"zone\":{\"default\":\"z1\"}}}],\"paths\":{\"/x\":{\"get\":{\"operationId\":\"ax\",\"responses\":{}}}}}")
                    (write "b.json"
                           "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://b.test\"}],\"paths\":{\"/y\":{\"get\":{\"operationId\":\"by\",\"responses\":{}}}}}")
                    (let [doc {:sourceDescriptions [{:name "a"
                                                     :type "openapi"
                                                     :url (.. dir "-a.json")}
                                                    {:name "b"
                                                     :type "openapi"
                                                     :url (.. dir "-b.json")}]
                               :workflows []}
                          clients (arazzo.build-clients doc
                                                        {:server-vars {:zone "z9"}})]
                      (os.remove (.. dir "-a.json"))
                      (os.remove (.. dir "-b.json"))
                      (assert.are.equal "https://z9.a.test/x"
                                        (clients.a.ax.url-for))
                      (assert.are.equal "https://b.test/y"
                                        (clients.b.by.url-for))))))
            (it "takes the variables of the chosen server"
                (fn []
                  (let [path (os.tmpname)]
                    (with-open [f (io.open path :w)]
                      (f:write "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://a.test\"},{\"url\":\"https://{region}.a.test\",\"variables\":{\"region\":{\"default\":\"us\"}}}],\"paths\":{\"/x\":{\"get\":{\"operationId\":\"ax\",\"responses\":{}}}}}"))
                    (let [clients (arazzo.build-clients {:sourceDescriptions [{:name "a"
                                                                               :type "openapi"
                                                                               :url path}]
                                                         :workflows []}
                                                        {:server-index 2
                                                         :server-vars {:region "eu"}})]
                      (os.remove path)
                      (assert.are.equal "https://eu.a.test/x"
                                        (clients.a.ax.url-for))))))
            (it "takes variables of servers an operation declares"
                (fn []
                  (let [path (os.tmpname)]
                    (with-open [f (io.open path :w)]
                      (f:write "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://api.example.com\"}],\"paths\":{\"/x\":{\"get\":{\"operationId\":\"getX\",\"servers\":[{\"url\":\"https://{region}.example.com\",\"variables\":{\"region\":{\"default\":\"eu\"}}}],\"responses\":{}}}}}"))
                    (let [clients (arazzo.build-clients {:sourceDescriptions [{:name "a"
                                                                               :type "openapi"
                                                                               :url path}]
                                                         :workflows []}
                                                        {:server-vars {:region "us"}})]
                      (os.remove path)
                      (assert.are.equal "https://us.example.com/x"
                                        (clients.a.get-x.url-for))))))
            (it "loads sources that don't say their type"
                (fn []
                  (let [clients (arazzo.build-clients {:sourceDescriptions [{:name "api"
                                                                             :url "./petstore.yaml"}]
                                                       :workflows []}
                                                      {}
                                                      "test/fixtures/flow.arazzo.json")]
                    (assert.is_not_nil clients.api))))
            (it "builds the same sources again from its cache"
                (fn []
                  (let [path (os.tmpname)]
                    (with-open [f (io.open path :w)]
                      (f:write "{\"openapi\":\"3.0.0\",\"info\":{},\"servers\":[{\"url\":\"https://{zone}.a.test\",\"variables\":{\"zone\":{\"default\":\"z1\"}}}],\"paths\":{\"/x\":{\"get\":{\"operationId\":\"ax\",\"responses\":{}}}}}"))
                    (let [doc {:sourceDescriptions [{:name "a"
                                                     :type "openapi"
                                                     :url path}]
                               :workflows []}
                          opts {:server-vars {:zone "z9"} :source-clients {}}
                          first (arazzo.build-clients doc opts)
                          (ok again) (pcall arazzo.build-clients doc opts)]
                      (os.remove path)
                      (assert.is_true ok again)
                      (assert.are.equal first.a again.a)))))
            (it "rejects server variables no source declares"
                (fn []
                  (let [doc {:sourceDescriptions [{:name "a"
                                                   :type "openapi"
                                                   :url "./petstore.yaml"}]
                             :workflows []}]
                    (assert.has.error #(arazzo.build-clients doc
                                                             {:server-vars {:nope "x"}}
                                                             "test/fixtures/flow.arazzo.json")
                                      "no openapi source declares server variable 'nope'"))))
            (it "rejects a server-index when several openapi sources exist"
                (fn []
                  (let [doc {:sourceDescriptions [{:name "a"
                                                   :type "openapi"
                                                   :url "./petstore.yaml"}
                                                  {:name "b"
                                                   :type "openapi"
                                                   :url "./petstore.yaml"}]
                             :workflows []}]
                    (assert.has.error #(arazzo.build-clients doc
                                                             {:server-index 2}
                                                             "test/fixtures/flow.arazzo.json")
                                      "server-index is ambiguous: the document has 2 openapi sources"))))
            (it "fails when a source cannot be loaded"
                (fn []
                  (let [doc {:sourceDescriptions [{:name "api"
                                                   :type "openapi"
                                                   :url "missing.yaml"}]
                             :workflows []}]
                    (assert.has.error #(arazzo.build-clients doc
                                                             {:load-schema #(error "offline"
                                                                                   0)})
                                      "source 'api': offline"))))
            (it "skips non-openapi sources"
                (fn []
                  (let [doc {:sourceDescriptions [{:name "ext"
                                                   :type "arazzo"
                                                   :url "other.yaml"}]
                             :workflows []}
                        clients (arazzo.build-clients doc {})]
                    (assert.are.same {} clients))))))

;; ---- run-workflow ----

(describe "run-workflow"
          (fn []
            (it "runs a single-step workflow and returns outputs"
                (fn []
                  (let [resp (ok-resp {:token "tok99"})
                        c (counter)
                        op (fn [] (c.inc) resp)
                        clients {:myapi (make-client {:getToken op})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "auth"
                                          :steps [{:stepId "step1"
                                                   :operationId "getToken"
                                                   :successCriteria [{:condition "$statusCode == 200"}]
                                                   :outputs {:tok "$response.body#/token"}}]
                                          :outputs {:token "$steps.step1.outputs.tok"}}]}
                        result (arazzo.run-workflow doc "auth" {} clients {})]
                    (assert.are.equal "tok99" result.outputs.token)
                    (assert.are.equal 1 (c.val)))))
            (it "executes onSuccess goto — skips to non-sequential step"
                (fn []
                  ;; s1 →(goto s3)→ s3; s2 is skipped entirely
                  (let [call-log []
                        make-op (fn [id]
                                  (fn []
                                    (table.insert call-log id)
                                    (ok-resp {})))
                        clients {:api (make-client {:op1 (make-op :s1)
                                                    :op2 (make-op :s2)
                                                    :op3 (make-op :s3)})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op1"
                                                   :successCriteria [{:condition "$statusCode == 200"}]
                                                   :onSuccess [{:type :goto
                                                                :stepId "s3"}]}
                                                  {:stepId "s2"
                                                   :operationId "op2"
                                                   :successCriteria [{:condition "$statusCode == 200"}]}
                                                  {:stepId "s3"
                                                   :operationId "op3"
                                                   :successCriteria [{:condition "$statusCode == 200"}]}]
                                          :outputs {}}]}]
                    (arazzo.run-workflow doc "wf" {} clients {})
                    (assert.are.same [:s1 :s3] call-log))))
            (it "executes onFailure end action"
                (fn []
                  (let [clients {:api (make-client {:failop (fn []
                                                              (ok-resp {:e "err"}
                                                                       500))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "failop"
                                                   :successCriteria [{:condition "$statusCode == 200"}]
                                                   :onFailure [{:type :end}]}]
                                          :outputs {}}]}
                        result (arazzo.run-workflow doc "wf" {} clients {})]
                    (assert.are.same {} result.outputs))))
            (it "raises on step failure with no action"
                (fn []
                  (let [clients {:api (make-client {:failop (fn []
                                                              (ok-resp {} 500))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "failop"
                                                   :successCriteria [{:condition "$statusCode == 200"}]}]
                                          :outputs {}}]}]
                    (assert.has.error (fn []
                                        (arazzo.run-workflow doc "wf" {}
                                                             clients {}))
                                      "step 's1' failed: $statusCode == 200 ($statusCode is 500); HTTP 500 {}"))))
            (it "passes inputs to steps via path parameters"
                (fn []
                  (let [received []
                        op (fn [req] (table.insert received req.path.id)
                             (ok-resp {}))
                        clients {:api (make-client {:getUser op})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "getUser"
                                                   :parameters [{:in :path
                                                                 :name "id"
                                                                 :value "$inputs.userId"}]
                                                   :successCriteria [{:condition "$statusCode == 200"}]}]
                                          :outputs {}}]}]
                    (arazzo.run-workflow doc "wf" {:userId "42"} clients {})
                    (assert.are.equal "42" (. received 1)))))
            (it "merges workflow-level parameters into steps"
                (fn []
                  (let [received []
                        op (fn [req] (table.insert received req.path.env)
                             (ok-resp {}))
                        clients {:api (make-client {:op op})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :parameters [{:in :path
                                                        :name "env"
                                                        :value "$inputs.env"}]
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :successCriteria [{:condition "$statusCode == 200"}]}]
                                          :outputs {}}]}]
                    (arazzo.run-workflow doc "wf" {:env "prod"} clients {})
                    (assert.are.equal "prod" (. received 1)))))
            (it "resolves requestBody.payload expression"
                (fn []
                  (let [received []
                        op (fn [req] (table.insert received req.body)
                             (ok-resp {}))
                        clients {:api (make-client {:createUser op})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "createUser"
                                                   :requestBody {:payload "$inputs.user"}
                                                   :successCriteria [{:condition "$statusCode == 200"}]}]
                                          :outputs {}}]}]
                    (arazzo.run-workflow doc "wf" {:user {:name "alice"}}
                                         clients {})
                    (assert.are.same {:name "alice"} (. received 1)))))
            (it "propagates step outputs via $steps expression"
                (fn []
                  (let [login-resp (ok-resp {:access_token "tok-abc"})
                        use-resp (ok-resp {:ok true})
                        token-used []
                        clients {:api (make-client {:login (fn [] login-resp)
                                                    :use (fn [req]
                                                           (table.insert token-used
                                                                         req.path.t)
                                                           use-resp)})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "login"
                                                   :operationId "login"
                                                   :successCriteria [{:condition "$statusCode == 200"}]
                                                   :outputs {:token "$response.body#/access_token"}}
                                                  {:stepId "use"
                                                   :operationId "use"
                                                   :parameters [{:in :path
                                                                 :name "t"
                                                                 :value "$steps.login.outputs.token"}]
                                                   :successCriteria [{:condition "$statusCode == 200"}]}]
                                          :outputs {}}]}]
                    (arazzo.run-workflow doc "wf" {} clients {})
                    (assert.are.equal "tok-abc" (. token-used 1)))))
            (it "runs sub-workflow and exposes its outputs"
                (fn []
                  (let [clients {:api (make-client {:op (fn [] (ok-resp {:v 7}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "inner"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :successCriteria [{:condition "$statusCode == 200"}]
                                                   :outputs {:val "$response.body#/v"}}]
                                          :outputs {:result "$steps.s1.outputs.val"}}
                                         {:workflowId "outer"
                                          :steps [{:stepId "sub"
                                                   :workflowId "inner"}]
                                          :outputs {:x "$steps.sub.outputs.result"}}]}
                        result (arazzo.run-workflow doc "outer" {} clients {})]
                    (assert.are.equal 7 result.outputs.x))))
            (it "detects goto loops"
                (fn []
                  (let [clients {:api (make-client {:op (fn [] (ok-resp {}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :successCriteria [{:condition "$statusCode == 200"}]
                                                   :onSuccess [{:type :goto
                                                                :stepId "s1"}]}]
                                          :outputs {}}]}]
                    (assert.has.error (fn []
                                        (arazzo.run-workflow doc "wf" {}
                                                             clients {}))
                                      "goto loop detected at: s1"))))
            (it "resolves operationPath via path index"
                (fn []
                  (let [resp (ok-resp {:id 1})
                        c (counter)
                        op (fn [] (c.inc) resp)
                        clients {:api {:list-users {:path "/users"
                                                    :method "get"
                                                    :url-for #"u"
                                                    :invoke op}}}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationPath "{$sourceDescriptions.api.url}#/paths/~1users/get"
                                                   :successCriteria [{:condition "$statusCode == 200"}]}]
                                          :outputs {}}]}]
                    (arazzo.run-workflow doc "wf" {} clients {})
                    (assert.are.equal 1 (c.val)))))
            (it "decodes percent-escapes in operationPath"
                (fn []
                  (let [c (counter)
                        clients {:api {:get-user {:path "/users/{id}"
                                                  :method "get"
                                                  :url-for #"u"
                                                  :invoke (fn []
                                                            (c.inc)
                                                            (ok-resp {}))}}}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationPath "{$sourceDescriptions.api.url}#/paths/~1users~1%7Bid%7D/get"}]}]}]
                    (arazzo.run-workflow doc "wf" {} clients {})
                    (assert.are.equal 1 (c.val)))))
            (it "raises on operationPath with missing source"
                (fn []
                  (let [clients {}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationPath "{$sourceDescriptions.missing.url}#/paths/~1users/get"}]
                                          :outputs {}}]}]
                    (assert.has.error (fn []
                                        (arazzo.run-workflow doc "wf" {}
                                                             clients {}))
                                      "operationPath: unknown source 'missing'"))))
            (it "calls on-step callback with running and done events"
                (fn []
                  (let [events []
                        clients {:api (make-client {:op (fn [] (ok-resp {}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :successCriteria [{:condition "$statusCode == 200"}]}]
                                          :outputs {}}]}
                        on-step (fn [ev] (table.insert events ev.status))]
                    (arazzo.run-workflow doc "wf" {} clients {:on-step on-step})
                    (assert.are.same [:workflow :running :done] events))))
            (it "reports a step after its criteria, the action taken, and each attempt"
                (fn []
                  (let [events []
                        states ["pending" "success"]
                        n (counter)
                        clients {:api (make-client {:poll (fn []
                                                            (n.inc)
                                                            (ok-resp {:state (. states
                                                                                (n.val))}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "wait"
                                                   :operationId "poll"
                                                   :successCriteria [{:condition "$response.body#/state == 'success'"}]
                                                   :onFailure [{:name "again"
                                                                :type "goto"
                                                                :stepId "wait"
                                                                :retryAfter 0
                                                                :criteria [{:condition "$response.body#/state == 'pending'"}]}]}]}]}]
                    (arazzo.run-workflow doc "wf" {} clients
                                         {:on-step #(table.insert events $)})
                    (assert.are.same [:workflow
                                      :running
                                      :done
                                      :action
                                      :running
                                      :done]
                                     (icollect [_ e (ipairs events)] e.status))
                    (let [[start run1 fail action run2 pass] events]
                      (assert.are.same [{:step "wait"
                                         :op-ref "poll"
                                         :calls "operation"}]
                                       start.steps)
                      (assert.are.equal "operation" run1.calls)
                      (assert.are.equal "wf" start.workflow)
                      (assert.are.equal 0 start.depth)
                      (assert.are.equal 1 run1.attempt)
                      (assert.are.equal 1 run1.index)
                      (assert.are.equal 1 run1.count)
                      (assert.is_false fail.passed)
                      (assert.are.equal "$response.body#/state == 'success' ($response.body#/state is \"pending\")"
                                        fail.failure)
                      (assert.are.equal 200 fail.response.status)
                      (assert.are.equal "goto" action.action.type)
                      (assert.are.equal "wait" action.action.stepId)
                      (assert.are.equal 0 action.wait)
                      (assert.are.equal 2 run2.attempt)
                      (assert.is_true pass.passed)
                      (assert.is_nil pass.failure)))))
            (it "sends a payload whose members are all missing as an empty object, with its replacements"
                (fn []
                  (let [sent []
                        clients {:api (make-client {:op (fn [req]
                                                          (table.insert sent
                                                                        req.body)
                                                          (ok-resp {}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :requestBody {:payload {:name "$inputs.name"}
                                                                 :replacements [{:target "/size"
                                                                                 :value 1}]}}]}]}]
                    (arazzo.run-workflow doc "wf" {} clients {})
                    (assert.are.same [{:size 1}] sent))))
            (it "cuts a long text body between characters"
                (fn []
                  (let [clients {:api (make-client {:op (fn []
                                                          (ok-resp (string.rep "é"
                                                                               600)
                                                                   500))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :successCriteria [{:condition "$statusCode == 200"}]}]}]}
                        (_ err) (pcall arazzo.run-workflow doc "wf" {} clients
                                       {})]
                    (assert.is_truthy (utf8.len err))
                    (assert.is_truthy (err:find (.. (string.rep "é" 500) "…")
                                                1 true)))))
            (it "reports a request that fails in transport"
                (fn []
                  (let [events []
                        clients {:api (make-client {:op (fn []
                                                          (error "connection refused"))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"}]}]}]
                    (assert.has.error #(arazzo.run-workflow doc "wf" {} clients
                                                            {:on-step #(table.insert events
                                                                                     $)}))
                    (let [done (. events (length events))]
                      (assert.are.equal :done done.status)
                      (assert.is_false done.passed)
                      (assert.is_truthy (done.error:find "connection refused" 1
                                                         true))))))
            (it "reports the steps of a sub-workflow one level deeper"
                (fn []
                  (let [events []
                        clients {:api (make-client {:op (fn [] (ok-resp {}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "outer"
                                          :steps [{:stepId "call"
                                                   :workflowId "inner"}]}
                                         {:workflowId "inner"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"}]}]}]
                    (arazzo.run-workflow doc "outer" {} clients
                                         {:on-step #(table.insert events $)})
                    (assert.are.same [[:workflow "outer" 0 nil]
                                      [:running "outer" 0 "call"]
                                      [:workflow "inner" 1 nil]
                                      [:running "inner" 1 "s1"]
                                      [:done "inner" 1 "s1"]
                                      [:done "outer" 0 "call"]]
                                     (icollect [_ e (ipairs events)]
                                       [e.status e.workflow e.depth e.step])))))))

;; ---- run-workflow: $response.body (no pointer) ----

(describe "run-workflow $response.body"
          (fn []
            (it "captures full response body as step output"
                (fn []
                  (let [body {:id 42 :name "alice"}
                        clients {:api (make-client {:op (fn [] (ok-resp body))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :successCriteria [{:condition "$statusCode == 200"}]
                                                   :outputs {:data "$response.body"}}]
                                          :outputs {:result "$steps.s1.outputs.data"}}]}
                        result (arazzo.run-workflow doc "wf" {} clients {})]
                    (assert.are.same body result.outputs.result))))
            (it "passes full body through requestBody payload table"
                (fn []
                  (let [received []
                        op (fn [req] (table.insert received req.body)
                             (ok-resp {}))
                        clients {:api (make-client {:op op})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :requestBody {:payload {:name "$inputs.name"
                                                                           :role "$inputs.role"}}
                                                   :successCriteria [{:condition "$statusCode == 200"}]}]
                                          :outputs {}}]}]
                    (arazzo.run-workflow doc "wf" {:name "bob" :role "admin"}
                                         clients {})
                    (assert.are.same {:name "bob" :role "admin"} (. received 1)))))
            (it "propagates full body between steps via $steps.id.response.body"
                (fn []
                  (let [first-body {:token "xyz"}
                        received []
                        clients {:api (make-client {:login (fn []
                                                             (ok-resp first-body))
                                                    :use (fn [req]
                                                           (table.insert received
                                                                         req.body)
                                                           (ok-resp {}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "login"
                                                   :operationId "login"
                                                   :successCriteria [{:condition "$statusCode == 200"}]}
                                                  {:stepId "use"
                                                   :operationId "use"
                                                   :requestBody {:payload "$steps.login.response.body"}
                                                   :successCriteria [{:condition "$statusCode == 200"}]}]
                                          :outputs {}}]}]
                    (arazzo.run-workflow doc "wf" {} clients {})
                    (assert.are.same first-body (. received 1)))))))

;; ---- run-workflow: multiple successCriteria (AND) ----

(describe "run-workflow multiple successCriteria"
          (fn []
            (it "passes when all criteria match"
                (fn []
                  (let [clients {:api (make-client {:op (fn []
                                                          (ok-resp {:state "done"}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :successCriteria [{:condition "$statusCode == 200"}
                                                                     {:condition "$response.body#/state == \"done\""}]}]
                                          :outputs {}}]}
                        result (arazzo.run-workflow doc "wf" {} clients {})]
                    (assert.are.same {} result.outputs))))
            (it "fails when second criterion does not match"
                (fn []
                  (let [clients {:api (make-client {:op (fn []
                                                          (ok-resp {:state "pending"}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :successCriteria [{:condition "$statusCode == 200"}
                                                                     {:condition "$response.body#/state == \"done\""}]
                                                   :onFailure [{:type :end}]}]
                                          :outputs {}}]}
                        result (arazzo.run-workflow doc "wf" {} clients {})]
                    (assert.are.same {} result.outputs))))))

;; ---- run-workflow: onSuccess criteria-gated action ----

(describe "run-workflow onSuccess criteria"
          (fn []
            (it "only fires action whose criteria match"
                (fn []
                  ;; two onSuccess actions; only the matching one should fire
                  (let [call-log []
                        make-op (fn [id]
                                  (fn [] (table.insert call-log id)
                                    (ok-resp {:v 1})))
                        clients {:api (make-client {:op1 (make-op :s1)
                                                    :op2 (make-op :s2)
                                                    :op3 (make-op :s3)})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op1"
                                                   :successCriteria [{:condition "$statusCode == 200"}]
                                                   :onSuccess [{:type :goto
                                                                :stepId "s2"
                                                                :criteria [{:condition "$response.body#/v == 99"}]}
                                                               {:type :goto
                                                                :stepId "s3"
                                                                :criteria [{:condition "$response.body#/v == 1"}]}]}
                                                  {:stepId "s2"
                                                   :operationId "op2"
                                                   :successCriteria [{:condition "$statusCode == 200"}]}
                                                  {:stepId "s3"
                                                   :operationId "op3"
                                                   :successCriteria [{:condition "$statusCode == 200"}]}]
                                          :outputs {}}]}]
                    (arazzo.run-workflow doc "wf" {} clients {})
                    (assert.are.same [:s1 :s3] call-log))))))

;; ---- run-workflow: onFailure goto (poll pattern) ----

(describe "run-workflow onFailure goto"
          (fn []
            (it "retries until success criterion met"
                (fn []
                  (let [calls (counter) ;; returns pending twice then done
                        op (fn []
                             (calls.inc)
                             (if (< (calls.val) 3)
                                 (ok-resp {:state "pending"})
                                 (ok-resp {:state "done"})))
                        clients {:api (make-client {:op op})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "poll"
                                                   :operationId "op"
                                                   :successCriteria [{:condition "$statusCode == 200"}
                                                                     {:condition "$response.body#/state == \"done\""}]
                                                   :onFailure [{:type :goto
                                                                :stepId "poll"}]
                                                   :outputs {:state "$response.body#/state"}}]
                                          :outputs {:state "$steps.poll.outputs.state"}}]}
                        result (arazzo.run-workflow doc "wf" {} clients {})]
                    (assert.are.equal 3 (calls.val))
                    (assert.are.equal "done" result.outputs.state))))))

(describe "run-workflow step output expressions"
          (fn []
            (it "works as step output expression"
                (fn []
                  (let [clients {:api (make-client {:list-users (fn []
                                                                  (ok-resp {:users [{:id "u1"
                                                                                     :name "alice"}
                                                                                    {:id "u2"
                                                                                     :name "bob"}]}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "find-user"
                                          :steps [{:stepId "list"
                                                   :operationId "list-users"
                                                   :successCriteria [{:condition "$statusCode == 200"}]
                                                   :outputs {:id {:context "$response.body"
                                                                  :selector "$.users[?@.name == '{$inputs.name}'].id"
                                                                  :type "jsonpath"}}}]
                                          :outputs {:id "$steps.list.outputs.id#/0"}}]}
                        result (arazzo.run-workflow doc "find-user"
                                                    {:name "bob"} clients {})]
                    (assert.are.equal "u2" result.outputs.id))))))

;; ---- operation resolution and parameters ----

(fn one-step-doc [step ?wf-params]
  {:arazzo "1.0.0"
   :info {}
   :workflows [{:workflowId "wf"
                :parameters ?wf-params
                :steps [(doto step
                          (tset :stepId "s1")
                          (tset :successCriteria
                                [{:condition "$statusCode == 200"}]))]
                :outputs {}}]})

(describe "run-workflow operation resolution"
          (fn []
            (it "finds camelCase operationId on kebab-keyed client"
                (fn []
                  (let [c (counter)
                        clients {:api {:get-pet-by-id {:operation-id "getPetById"
                                                       :method "get"
                                                       :url-for #"u"
                                                       :invoke (fn [] (c.inc)
                                                                 (ok-resp {}))}}}]
                    (arazzo.run-workflow (one-step-doc {:operationId "getPetById"})
                                         "wf" {} clients {})
                    (assert.are.equal 1 (c.val)))))
            (it "scopes $sourceDescriptions operationId to that source"
                (fn []
                  (let [log []
                        clients {:a (make-client {:op (fn []
                                                        (table.insert log :a)
                                                        (ok-resp {}))})
                                 :b (make-client {:op (fn []
                                                        (table.insert log :b)
                                                        (ok-resp {}))})}]
                    (arazzo.run-workflow (one-step-doc {:operationId "$sourceDescriptions.b.op"})
                                         "wf" {} clients {})
                    (assert.are.same [:b] log))))
            (it "rejects a plain operationId found in several sources"
                (fn []
                  (let [clients {:a (make-client {:op #(ok-resp {})})
                                 :b (make-client {:op #(ok-resp {})})}]
                    (assert.has.error #(arazzo.run-workflow (one-step-doc {:operationId "op"})
                                                            "wf" {} clients {})
                                      "operationId 'op' is in several sources (a, b): use $sourceDescriptions.NAME.op"))))))

(describe "run-workflow step details"
          (fn []
            (it "sends header and cookie parameters"
                (fn []
                  (let [seen []
                        clients {:api (make-client {:op (fn [req]
                                                          (table.insert seen
                                                                        req)
                                                          (ok-resp {}))})}]
                    (arazzo.run-workflow (one-step-doc {:operationId "op"
                                                        :parameters [{:in "header"
                                                                      :name "X-Req"
                                                                      :value "a"}
                                                                     {:in "cookie"
                                                                      :name "sid"
                                                                      :value "s1"}
                                                                     {:in "cookie"
                                                                      :name "t"
                                                                      :value 2}
                                                                     {:in "cookie"
                                                                      :name "ids"
                                                                      :value [1
                                                                              2]}]})
                                         "wf" {} clients {})
                    (assert.are.same {:x-req "a"
                                      :cookie "sid=s1; t=2; ids=1,2"}
                                     (. seen 1 :headers)))))
            (it "fails a step whose operation does not exist"
                (fn []
                  (assert.has.error #(arazzo.run-workflow (one-step-doc {:operationId "nope"})
                                                          "wf" {} {:api {}} {})
                                    "step 's1': operation not found: nope")))
            (it "runs a workflow named by a retry action before retrying"
                (fn []
                  (let [log []
                        n (counter)
                        clients {:api (make-client {:op (fn []
                                                          (n.inc)
                                                          (table.insert log :op)
                                                          (ok-resp {}
                                                                   (if (= 1
                                                                          (n.val))
                                                                       500
                                                                       200)))
                                                    :fix (fn []
                                                           (table.insert log
                                                                         :fix)
                                                           (ok-resp {}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :successCriteria [{:condition "$statusCode == 200"}]
                                                   :onFailure [{:name "again"
                                                                :type "retry"
                                                                :workflowId "repair"
                                                                :retryLimit 1}]}]}
                                         {:workflowId "repair"
                                          :steps [{:stepId "f"
                                                   :operationId "fix"}]}]}]
                    (arazzo.run-workflow doc "wf" {} clients {})
                    (assert.are.same [:op :fix :op] log))))
            (it "continues with another workflow on a goto workflowId"
                (fn []
                  (let [log []
                        clients {:api (make-client {:a (fn []
                                                         (table.insert log :a)
                                                         (ok-resp {}))
                                                    :b (fn []
                                                         (table.insert log :b)
                                                         (ok-resp {}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "a"
                                                   :onSuccess [{:name "next"
                                                                :type "goto"
                                                                :workflowId "other"}]}
                                                  {:stepId "s2"
                                                   :operationId "a"}]}
                                         {:workflowId "other"
                                          :steps [{:stepId "o"
                                                   :operationId "b"}]}]}]
                    (arazzo.run-workflow doc "wf" {} clients {})
                    (assert.are.same [:a :b] log))))
            (it "loads and runs a document from a file"
                (fn []
                  (let [clients {:api (make-client {:getUser #(ok-resp {:id 1})})}
                        result (arazzo.run "test/fixtures/simple.arazzo.json"
                                           "simple" nil {: clients})]
                    (assert.are.equal 200
                                      (. result.steps :step1 :response :status)))))))

(describe "step failures"
          (fn []
            (it "lets onFailure retry a request that failed in transport"
                (fn []
                  (let [n (counter)
                        clients {:api (make-client {:op (fn []
                                                          (n.inc)
                                                          (if (= 1 (n.val))
                                                              (error "connection refused"
                                                                     0)
                                                              (ok-resp {})))})}
                        doc (one-step-doc {:operationId "op"
                                           :onFailure [{:name "again"
                                                        :type "retry"
                                                        :retryLimit 2}]})]
                    (arazzo.run-workflow doc "wf" {} clients {})
                    (assert.are.equal 2 (n.val)))))
            (it "reports a transport failure without internal locations"
                (fn []
                  (let [clients {:api (make-client {:op #(error "connection refused"
                                                                0)})}
                        (ok err) (pcall arazzo.run-workflow
                                        (one-step-doc {:operationId "op"}) "wf"
                                        {} clients {})]
                    (assert.is_false ok)
                    (assert.are.equal "step 's1' failed: request failed: connection refused"
                                      err))))
            (it "evaluates a workflow step's criteria without the previous response"
                (fn []
                  (let [clients {:api (make-client {:bad #(ok-resp {} 500)
                                                    :good #(ok-resp {})})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s0"
                                                   :operationId "bad"
                                                   :onFailure [{:name "go"
                                                                :type "goto"
                                                                :stepId "s"}]}
                                                  {:stepId "s"
                                                   :workflowId "sub"
                                                   :successCriteria [{:condition "$statusCode == 500"}]}]}
                                         {:workflowId "sub"
                                          :steps [{:stepId "g"
                                                   :operationId "good"}]}]}]
                    (tset (. doc.workflows 1 :steps 1) :successCriteria
                          [{:condition "$statusCode == 200"}])
                    (assert.has.error #(arazzo.run-workflow doc "wf" {} clients
                                                            {})))))))

(describe "retry actions"
          (fn []
            (it "run the step named by stepId, then retry"
                (fn []
                  (let [log []
                        n (counter)
                        clients {:api (make-client {:a (fn []
                                                         (n.inc)
                                                         (table.insert log :a)
                                                         (ok-resp {}
                                                                  (if (= 1
                                                                         (n.val))
                                                                      401
                                                                      200)))
                                                    :refresh (fn []
                                                               (table.insert log
                                                                             :refresh)
                                                               (ok-resp {}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s"
                                                   :operationId "a"
                                                   :successCriteria [{:condition "$statusCode == 200"}]
                                                   :onSuccess [{:name "done"
                                                                :type "end"}]
                                                   :onFailure [{:name "re"
                                                                :type "retry"
                                                                :stepId "r"}]}
                                                  {:stepId "r"
                                                   :operationId "refresh"}]}]}]
                    (arazzo.run-workflow doc "wf" {} clients {})
                    (assert.are.same [:a :refresh :a] log))))
            (it "wait as long as the response's Retry-After asks"
                (fn []
                  (let [slept []
                        socket (require :socket)
                        real-sleep socket.sleep
                        n (counter)
                        clients {:api (make-client {:op (fn []
                                                          (n.inc)
                                                          (if (= 1 (n.val))
                                                              {:status 503
                                                               :headers {:retry-after "2"}
                                                               :body {}}
                                                              (ok-resp {})))})}
                        doc (one-step-doc {:operationId "op"
                                           :onFailure [{:name "again"
                                                        :type "retry"
                                                        :retryAfter 7}]})]
                    (set socket.sleep #(table.insert slept $))
                    (let [(ok err) (pcall arazzo.run-workflow doc "wf" {}
                                          clients {})]
                      (set socket.sleep real-sleep)
                      (assert.is_true ok err))
                    (assert.are.same [2] slept))))
            (it "cap the response's Retry-After at max-wait"
                (fn []
                  (let [slept []
                        socket (require :socket)
                        real-sleep socket.sleep
                        run (fn [opts]
                              (let [n (counter)
                                    clients {:api (make-client {:op (fn []
                                                                      (n.inc)
                                                                      (if (= 1
                                                                             (n.val))
                                                                          {:status 503
                                                                           :headers {:retry-after "1e12"}
                                                                           :body {}}
                                                                          (ok-resp {})))})}]
                                (arazzo.run-workflow (one-step-doc {:operationId "op"
                                                                    :onFailure [{:name "again"
                                                                                 :type "retry"
                                                                                 :retryAfter 2}]})
                                                     "wf" {} clients opts)))]
                    (set socket.sleep #(table.insert slept $))
                    (let [(ok err) (pcall #(do
                                             (run {})
                                             (run {:max-wait 10})))]
                      (set socket.sleep real-sleep)
                      (assert.is_true ok err))
                    (assert.are.same [300 10] slept))))))

(describe "request bodies"
          (fn []
            (it "use contentType and apply replacements"
                (fn []
                  (let [seen []
                        clients {:api (make-client {:op (fn [req]
                                                          (table.insert seen
                                                                        req)
                                                          (ok-resp {}))})}]
                    (arazzo.run-workflow (one-step-doc {:operationId "op"
                                                        :requestBody {:contentType "application/x-www-form-urlencoded"
                                                                      :payload {:a {:b 1}
                                                                                :keep "k"}
                                                                      :replacements [{:target "/a/b"
                                                                                      :value "$inputs.x"}
                                                                                     {:target "/c"
                                                                                      :value 3}]}})
                                         "wf" {:x "new"} clients {})
                    (assert.are.equal "application/x-www-form-urlencoded"
                                      (. seen 1 :headers :content-type))
                    (assert.are.same {:a {:b "new"} :keep "k" :c 3}
                                     (. seen 1 :body)))))))

(describe "request body replacements"
          (fn []
            (it "leave the inputs they start from alone"
                (fn []
                  (let [seen []
                        clients {:api (make-client {:op (fn [req]
                                                          (table.insert seen
                                                                        req)
                                                          (ok-resp {}))})}
                        inputs {:pet {:name "rex"}}]
                    (arazzo.run-workflow (one-step-doc {:operationId "op"
                                                        :requestBody {:payload "$inputs.pet"
                                                                      :replacements [{:target "/name"
                                                                                      :value "changed"}]}})
                                         "wf" inputs clients {})
                    (assert.are.same {:name "changed"} (. seen 1 :body))
                    (assert.are.same {:pet {:name "rex"}} inputs))))
            (it "append to an array with -"
                (fn []
                  (let [json (require :ezu.json)
                        seen []
                        clients {:api (make-client {:op (fn [req]
                                                          (table.insert seen
                                                                        req)
                                                          (ok-resp {}))})}
                        run #(arazzo.run-workflow (one-step-doc {:operationId "op"
                                                                 :requestBody {:payload "$inputs.pet"
                                                                               :replacements [{:target $1
                                                                                               :value "b"}]}})
                                                  "wf"
                                                  {:pet {:tags (json.array ["a"])}}
                                                  clients {})]
                    (run "/tags/-")
                    (assert.are.same ["a" "b"] (. seen 1 :body :tags))
                    (let [(ok err) (pcall run "/tags/x")]
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find
                                           "not an array index" 1 true))))))))

(describe "workflow inputs from another file"
          (fn []
            (it "resolve against the document's location"
                (fn []
                  (let [dir (os.tmpname)]
                    (os.remove dir)
                    (os.execute (.. "mkdir -p '" dir "'"))
                    (with-open [f (io.open (.. dir "/inputs.json") :w)]
                      (f:write "{\"W\":{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"integer\",\"default\":5}}}}"))
                    (with-open [f (io.open (.. dir "/flow.json") :w)]
                      (f:write "{\"arazzo\":\"1.0.0\",\"info\":{},\"workflows\":[{\"workflowId\":\"w\",\"inputs\":{\"$ref\":\"inputs.json#/W\"},\"steps\":[],\"outputs\":{\"n\":\"$inputs.n\"}}]}"))
                    (let [(ok result) (pcall arazzo.run (.. dir "/flow.json")
                                             "w" {} {:clients {}})]
                      (os.execute (.. "rm -rf '" dir "'"))
                      (assert.is_true ok result)
                      (assert.are.equal 5 result.outputs.n)))))))

(describe "parameters"
          (fn []
            (it "must say where they go"
                (fn []
                  (assert.has.error #(arazzo.run-workflow (one-step-doc {:operationId "op"
                                                                         :parameters [{:name "id"
                                                                                       :value "1"}]})
                                                          "wf" {}
                                                          {:api (make-client {:op #(ok-resp {})})}
                                                          {})
                                    "step 's1': parameter 'id' has no 'in' (path, query, header or cookie)")))
            (it "are referenced with reference, not $ref"
                (fn []
                  (assert.has.error #(arazzo.run-workflow (one-step-doc {:operationId "op"
                                                                         :parameters [{:$ref "#/components/parameters/p"}]})
                                                          "wf" {}
                                                          {:api (make-client {:op #(ok-resp {})})}
                                                          {})
                                    "step 's1': refer to reusable parameters with reference: $components.parameters.NAME, not $ref")))))

(describe "workflow input defaults"
          (fn []
            (it "fill inputs that were not given"
                (fn []
                  (let [seen []
                        clients {:api (make-client {:op (fn [req]
                                                          (table.insert seen
                                                                        req.query)
                                                          (ok-resp {}))})}
                        doc (doto (one-step-doc {:operationId "op"
                                                 :parameters [{:name "status"
                                                               :in "query"
                                                               :value "$inputs.status"}
                                                              {:name "limit"
                                                               :in "query"
                                                               :value "$inputs.limit"}]})
                              (tset :workflows 1 :inputs
                                    {:type "object"
                                     :properties {:status {:type "string"
                                                           :default "available"}
                                                  :limit {:type "integer"
                                                          :default 10}
                                                  :anything true}}))]
                    (arazzo.run-workflow doc "wf" {:limit 3} clients {})
                    (assert.are.same [{:status "available" :limit 3}] seen))))
            (it "take boolean input schemas"
                (fn []
                  (let [clients {:api (make-client {:op #(ok-resp {})})}
                        doc (doto (one-step-doc {:operationId "op"})
                              (tset :workflows 1 :inputs true))]
                    (assert.has_no.errors #(arazzo.run-workflow doc "wf" {}
                                                                clients {})))))))

(describe "run-workflow parameters"
          (fn []
            (it "passes path params by name regardless of order"
                (fn []
                  (let [seen []
                        clients {:api (make-client {:op (fn [req]
                                                          (table.insert seen
                                                                        req.path)
                                                          (ok-resp {}))})}]
                    (arazzo.run-workflow (one-step-doc {:operationId "op"
                                                        :parameters [{:in :path
                                                                      :name "petId"
                                                                      :value 2}
                                                                     {:in :path
                                                                      :name "ownerId"
                                                                      :value 1}]})
                                         "wf" {} clients {})
                    (assert.are.same {:petId 2 :ownerId 1} (. seen 1)))))
            (it "lets step parameters override workflow parameters"
                (fn []
                  (let [seen []
                        clients {:api (make-client {:op (fn [req]
                                                          (table.insert seen
                                                                        req.query)
                                                          (ok-resp {}))})}]
                    (arazzo.run-workflow (one-step-doc {:operationId "op"
                                                        :parameters [{:in :query
                                                                      :name "env"
                                                                      :value "step"}]}
                                                       [{:in :query
                                                         :name "env"
                                                         :value "wf"}])
                                         "wf" {} clients {})
                    (assert.are.same {:env "step"} (. seen 1)))))
            (it "sends query params without a body"
                (fn []
                  (let [seen []
                        clients {:api (make-client {:op (fn [req]
                                                          (table.insert seen
                                                                        req)
                                                          (ok-resp {}))})}]
                    (arazzo.run-workflow (one-step-doc {:operationId "op"
                                                        :parameters [{:in :query
                                                                      :name "q"
                                                                      :value "x"}]})
                                         "wf" {} clients {})
                    (assert.is_nil (. seen 1 :body))
                    (assert.are.same {:q "x"} (. seen 1 :query)))))))

(describe "run-workflow workflows and actions"
          (fn []
            (it "exposes sub-workflow outputs via $workflows"
                (fn []
                  (let [clients {:api (make-client {:op (fn [] (ok-resp {:v 7}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "inner"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :outputs {:val "$response.body#/v"}}]
                                          :outputs {:result "$steps.s1.outputs.val"}}
                                         {:workflowId "outer"
                                          :steps [{:stepId "sub"
                                                   :workflowId "inner"}]
                                          :outputs {:x "$workflows.inner.outputs.result"}}]}
                        result (arazzo.run-workflow doc "outer" {} clients {})]
                    (assert.are.equal 7 result.outputs.x))))
            (it "retries a failing step up to retryLimit"
                (fn []
                  (let [c (counter)
                        op (fn []
                             (c.inc)
                             (ok-resp {} (if (< (c.val) 3) 503 200)))
                        clients {:api (make-client {:op op})}]
                    (arazzo.run-workflow (one-step-doc {:operationId "op"
                                                        :onFailure [{:name "again"
                                                                     :type :retry
                                                                     :retryAfter 0
                                                                     :retryLimit 2}]})
                                         "wf" {} clients {})
                    (assert.are.equal 3 (c.val)))))
            (it "fails once retryLimit is exhausted"
                (fn []
                  (let [c (counter)
                        clients {:api (make-client {:op (fn [] (c.inc)
                                                          (ok-resp {} 503))})}]
                    (assert.has.error #(arazzo.run-workflow (one-step-doc {:operationId "op"
                                                                           :onFailure [{:name "again"
                                                                                        :type :retry
                                                                                        :retryAfter 0
                                                                                        :retryLimit 1}]})
                                                            "wf" {} clients {}))
                    (assert.are.equal 2 (c.val)))))
            (it "retries once when retryLimit is absent"
                (fn []
                  (let [c (counter)
                        clients {:api (make-client {:op (fn [] (c.inc)
                                                          (ok-resp {} 503))})}]
                    (assert.has.error #(arazzo.run-workflow (one-step-doc {:operationId "op"
                                                                           :onFailure [{:name "again"
                                                                                        :type :retry
                                                                                        :retryAfter 0}]})
                                                            "wf" {} clients {}))
                    (assert.are.equal 2 (c.val)))))
            (it "resolves $components parameter and action references"
                (fn []
                  (let [seen []
                        clients {:api (make-client {:op (fn [req]
                                                          (table.insert seen
                                                                        req.query)
                                                          (ok-resp {}))
                                                    :other (fn []
                                                             (table.insert seen
                                                                           :other)
                                                             (ok-resp {}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :components {:parameters {:env {:name "env"
                                                             :in "query"
                                                             :value "prod"}
                                                       :page {:name "page"
                                                              :in "query"
                                                              :value "1"}}
                                          :successActions {:finish {:name "finish"
                                                                    :type "end"}}}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :parameters [{:reference "$components.parameters.env"}
                                                                {:reference "$components.parameters.page"
                                                                 :value "2"}]
                                                   :onSuccess [{:reference "$components.successActions.finish"}]}
                                                  {:stepId "s2"
                                                   :operationId "other"}]
                                          :outputs {}}]}]
                    (arazzo.run-workflow doc "wf" {} clients {})
                    (assert.are.same [{:env "prod" :page "2"}] seen))))
            (it "applies workflow-level failureActions to steps without their own"
                (fn []
                  (let [c (counter)
                        clients {:api (make-client {:op (fn []
                                                          (c.inc)
                                                          (ok-resp {}
                                                                   (if (< (c.val)
                                                                          2)
                                                                       503
                                                                       200)))})}
                        doc (one-step-doc {:operationId "op"})]
                    (tset (. doc.workflows 1) :failureActions
                          [{:name "r" :type "retry" :retryAfter 0}])
                    (arazzo.run-workflow doc "wf" {} clients {})
                    (assert.are.equal 2 (c.val))))
                (it "exposes $method and $url of the step request"
                    (fn []
                      (let [clients {:api (make-client {:op (fn [] (ok-resp {}))})}
                            result (arazzo.run-workflow {:arazzo "1.0.0"
                                                         :info {}
                                                         :workflows [{:workflowId "wf"
                                                                      :steps [{:stepId "s1"
                                                                               :operationId "op"
                                                                               :parameters [{:in "query"
                                                                                             :name "a"
                                                                                             :value "1"}]
                                                                               :outputs {:m "$method"
                                                                                         :u "$url"}}]
                                                                      :outputs {:m "$steps.s1.outputs.m"
                                                                                :u "$steps.s1.outputs.u"}}]}
                                                        "wf" {} clients {})]
                        (assert.are.same {:m "GET" :u "https://api.test/op?q"}
                                         result.outputs)))))
            (it "records steps in execution order"
                (fn []
                  (let [clients {:api (make-client {:op (fn [] (ok-resp {}))})}
                        result (arazzo.run-workflow {:arazzo "1.0.0"
                                                     :info {}
                                                     :workflows [{:workflowId "wf"
                                                                  :steps [{:stepId "zeta"
                                                                           :operationId "op"}
                                                                          {:stepId "alpha"
                                                                           :operationId "op"}]}]}
                                                    "wf" {} clients {})]
                    (assert.are.same ["zeta" "alpha"] result.step-order)))
                (it "keeps workflow-level actions that a step does not override"
                    (fn []
                      (let [log []
                            clients {:api (make-client {:op (fn []
                                                              (table.insert log
                                                                            :op)
                                                              (ok-resp {} 500))
                                                        :cleanup (fn []
                                                                   (table.insert log
                                                                                 :cleanup)
                                                                   (ok-resp {}))})}
                            doc {:arazzo "1.0.0"
                                 :info {}
                                 :workflows [{:workflowId "wf"
                                              :failureActions [{:name "to-cleanup"
                                                                :type "goto"
                                                                :stepId "c"}]
                                              :steps [{:stepId "s1"
                                                       :operationId "op"
                                                       :successCriteria [{:condition "$statusCode == 200"}]
                                                       :onFailure [{:name "again"
                                                                    :type "retry"
                                                                    :retryAfter 0
                                                                    :retryLimit 1}]
                                                       :onSuccess [{:name "done"
                                                                    :type "end"}]}
                                                      {:stepId "c"
                                                       :operationId "cleanup"}]}]}]
                        (arazzo.run-workflow doc "wf" {} clients {})
                        (assert.are.same [:op :op :cleanup] log))))
                (it "lets a step action replace the workflow action with the same name"
                    (fn []
                      (let [log []
                            clients {:api (make-client {:op (fn []
                                                              (table.insert log
                                                                            :op)
                                                              (ok-resp {} 500))
                                                        :other (fn []
                                                                 (table.insert log
                                                                               :other)
                                                                 (ok-resp {}))})}
                            doc {:arazzo "1.0.0"
                                 :info {}
                                 :workflows [{:workflowId "wf"
                                              :failureActions [{:name "f"
                                                                :type "goto"
                                                                :stepId "other"}]
                                              :steps [{:stepId "s1"
                                                       :operationId "op"
                                                       :successCriteria [{:condition "$statusCode == 200"}]
                                                       :onFailure [{:name "f"
                                                                    :type "end"}]}
                                                      {:stepId "other"
                                                       :operationId "other"}]}]}]
                        (arazzo.run-workflow doc "wf" {} clients {})
                        (assert.are.same [:op] log)))))
            (it "allows raising the goto limit"
                (fn []
                  (let [c (counter)
                        clients {:api (make-client {:op (fn []
                                                          (c.inc)
                                                          (ok-resp {:done (>= (c.val)
                                                                              60)}))})}
                        doc (one-step-doc {:operationId "op"
                                           :onSuccess [{:name "poll"
                                                        :type "goto"
                                                        :stepId "s1"
                                                        :criteria [{:condition "$response.body#/done == false"}]}]})]
                    (assert.has.error #(arazzo.run-workflow doc "wf" {} clients
                                                            {}))
                    (let [c2 (counter)
                          clients2 {:api (make-client {:op (fn []
                                                             (c2.inc)
                                                             (ok-resp {:done (>= (c2.val)
                                                                                 60)}))})}]
                      (arazzo.run-workflow doc "wf" {} clients2
                                           {:max-gotos 100})
                      (assert.are.equal 60 (c2.val))))))))

(describe "workflow introspection"
          (fn []
            (it "takes the positional inputs a workflow declares, never the steps' order"
                (fn []
                  (let [wf {:x-ezu-args ["first" "second"]
                            :steps [{:parameters [{:in :path
                                                   :name "b"
                                                   :value "$inputs.second"}]}]}]
                    (assert.are.same ["first" "second"]
                                     (arazzo.positional-inputs wf))
                    (assert.are.same []
                                     (arazzo.positional-inputs {:steps (. wf
                                                                          :steps)})))))
            (it "resolves $ref'd inputs schemas against the document"
                (fn []
                  (let [doc {:components {:inputs {:create {:type "object"
                                                            :properties {:zip {:type "string"}}}}}}
                        wf {:inputs {:$ref "#/components/inputs/create"}}]
                    (assert.are.same {:type "object"
                                      :properties {:zip {:type "string"}}}
                                     (arazzo.workflow-inputs doc wf)))))))

(describe "sub-workflow steps"
          (fn []
            (fn doc-with [outer-step ?inner-ok]
              {:arazzo "1.0.0"
               :info {}
               :workflows [{:workflowId "inner"
                            :steps [{:stepId "i1"
                                     :operationId (if (= false ?inner-ok)
                                                      "fail"
                                                      "op")
                                     :successCriteria [{:condition "$statusCode == 200"}]
                                     :outputs {:v "$response.body#/v"}}]
                            :outputs {:result "$steps.i1.outputs.v"}}
                           {:workflowId "outer"
                            :steps [(doto outer-step (tset :stepId "sub")
                                      (tset :workflowId "inner"))
                                    {:stepId "after" :operationId "after"}]
                            :outputs {:x "$steps.sub.outputs.x"
                                      :raw "$steps.sub.outputs.result"}}]})

            (fn clients-logging [log]
              {:api (make-client {:op (fn [] (table.insert log :op)
                                        (ok-resp {:v 7}))
                                  :fail (fn [] (table.insert log :fail)
                                          (ok-resp {} 500))
                                  :after (fn [] (table.insert log :after)
                                           (ok-resp {}))})})

            (it "maps step outputs from the sub-workflow"
                (fn []
                  (let [result (arazzo.run-workflow (doc-with {:outputs {:x "$workflows.inner.outputs.result"}})
                                                    "outer" {}
                                                    (clients-logging []) {})]
                    (assert.are.equal 7 result.outputs.x))))
            (it "keeps exposing the sub-workflow outputs when the step declares none"
                (fn []
                  (let [result (arazzo.run-workflow (doc-with {}) "outer" {}
                                                    (clients-logging []) {})]
                    (assert.are.equal 7 result.outputs.raw))))
            (it "applies successCriteria and actions"
                (fn []
                  (let [log []]
                    (arazzo.run-workflow (doc-with {:successCriteria [{:condition "$workflows.inner.outputs.result == 8"}]
                                                    :onFailure [{:name "stop"
                                                                 :type "end"}]})
                                         "outer" {} (clients-logging log) {})
                    (assert.are.same [:op] log))))
            (it "lets onFailure handle a failing sub-workflow"
                (fn []
                  (let [log []]
                    (arazzo.run-workflow (doc-with {:onFailure [{:name "skip"
                                                                 :type "goto"
                                                                 :stepId "after"}]}
                                                   false)
                                         "outer" {} (clients-logging log) {})
                    (assert.are.same [:fail :after] log))))
            (it "reports a failing sub-workflow without actions"
                (fn []
                  (let [(ok err) (pcall arazzo.run-workflow (doc-with {} false)
                                        "outer" {} (clients-logging []) {})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "step 'sub' (inner) › step 'i1' failed: $statusCode == 200 ($statusCode is 500)"
                                         1 true)))))))

(describe "goto limit"
          (fn []
            (it "allows exactly max-gotos gotos to a step"
                (fn []
                  (let [c (counter)
                        clients {:api (make-client {:op (fn [] (c.inc)
                                                          (ok-resp {}))})}
                        doc (one-step-doc {:operationId "op"
                                           :onSuccess [{:name "again"
                                                        :type "goto"
                                                        :stepId "s1"
                                                        :criteria [{:condition "$statusCode == 200"}]}]})]
                    (assert.has.error #(arazzo.run-workflow doc "wf" {} clients
                                                            {:max-gotos 3}))
                    (assert.are.equal 4 (c.val)))))))

(describe "workflow dependsOn"
          (fn []
            (it "runs dependencies first and exposes their outputs"
                (fn []
                  (let [log []
                        clients {:api (make-client {:login (fn []
                                                             (table.insert log
                                                                           :login)
                                                             (ok-resp {:t "tok"}))
                                                    :use (fn []
                                                           (table.insert log
                                                                         :use)
                                                           (ok-resp {}))})}
                        doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "auth"
                                          :steps [{:stepId "l"
                                                   :operationId "login"
                                                   :outputs {:t "$response.body#/t"}}]
                                          :outputs {:token "$steps.l.outputs.t"}}
                                         {:workflowId "main"
                                          :dependsOn ["auth"]
                                          :steps [{:stepId "u"
                                                   :operationId "use"}]
                                          :outputs {:seen "$workflows.auth.outputs.token"}}]}
                        result (arazzo.run-workflow doc "main" {} clients {})]
                    (assert.are.same [:login :use] log)
                    (assert.are.equal "tok" result.outputs.seen))))))

(describe "workflow cycles"
          (fn []
            (it "reports dependsOn cycles"
                (fn []
                  (let [doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "a"
                                          :dependsOn ["b"]
                                          :steps []}
                                         {:workflowId "b"
                                          :dependsOn ["a"]
                                          :steps []}]}
                        (ok err) (pcall arazzo.run-workflow doc "a" {} {} {})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "workflow cycle: a -> b -> a" 1 true)))))
            (it "reports a step calling its own workflow"
                (fn []
                  (let [doc {:arazzo "1.0.0"
                             :info {}
                             :workflows [{:workflowId "w"
                                          :steps [{:stepId "s" :workflowId "w"}]}]}
                        (ok err) (pcall arazzo.run-workflow doc "w" {} {} {})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "workflow cycle: w -> w" 1 true)))))))

;; ---- Arazzo 1.1 ----

(fn recording-client [routes]
  "A fake client whose operations answer from routes {operationId (fn [req])}
and record their requests in the returned list."
  (let [seen []]
    (values (collect [id f (pairs routes)]
              (.. "op-" id)
              {:operation-id id
               :method "get"
               :url-for #(.. "https://api.test/" id)
               :invoke (fn [req]
                         (table.insert seen [id req])
                         (f req))}) seen)))

(describe "Arazzo 1.1 workflows"
          (fn []
            (it "look up an id by name with a selector, then use it"
                (fn []
                  (let [(client seen) (recording-client {:listTemplates #(ok-resp {:templates [{:id "t1"
                                                                                                :name "Debian"}
                                                                                               {:id "t2"
                                                                                                :name "Ubuntu"}]})
                                                         :create #(ok-resp {:id "vm1"})})
                        doc {:arazzo "1.1.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "find"
                                                   :operationId "listTemplates"
                                                   :outputs {:id {:context "$response.body"
                                                                  :selector "$.templates[?@.name == '{$inputs.template}'].id"
                                                                  :type "jsonpath"}}}
                                                  {:stepId "make"
                                                   :operationId "create"
                                                   :requestBody {:payload {:template {:id "$steps.find.outputs.id#/0"}}}}]
                                          :outputs {:vm "$steps.make.outputs.vm"}}]}]
                    (arazzo.run-workflow doc "wf" {:template "Ubuntu"}
                                         {:api client} {})
                    (assert.are.same {:template {:id "t2"}} (. seen 2 2 :body)))))
            (it "replace with a JSONPath target, every node it selects"
                (fn []
                  (let [(client seen) (recording-client {:op #(ok-resp {})})
                        json (require :ezu.json)]
                    (arazzo.run-workflow (one-step-doc {:operationId "op"
                                                        :requestBody {:payload {:items (json.array [{:sku "a"
                                                                                                     :qty 1}
                                                                                                    {:sku "b"
                                                                                                     :qty 2}])}
                                                                      :replacements [{:target "$.items[?@.sku == 'b'].qty"
                                                                                      :targetSelectorType "jsonpath"
                                                                                      :value 7}]}})
                                         "wf" {} {:api client} {})
                    (assert.are.same [{:sku "a" :qty 1} {:sku "b" :qty 7}]
                                     (. seen 1 2 :body :items))
                    (let [(ok err) (pcall arazzo.run-workflow
                                          (one-step-doc {:operationId "op"
                                                         :requestBody {:payload {:a 1}
                                                                       :replacements [{:target "$.nope"
                                                                                       :targetSelectorType "jsonpath"
                                                                                       :value 7}]}})
                                          "wf" {} {:api client} {})]
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find
                                           "selects nothing" 1 true))))))
            (it "pass parameters to the workflow an action goes to"
                (fn []
                  (let [(client seen) (recording-client {:op #(ok-resp {} 503)
                                                         :other #(ok-resp {})})
                        doc {:arazzo "1.1.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "s1"
                                                   :operationId "op"
                                                   :successCriteria [{:condition "$statusCode == 200"}]
                                                   :onFailure [{:name "fallback"
                                                                :type :goto
                                                                :workflowId "other"
                                                                :parameters [{:name "reason"
                                                                              :value "$statusCode"}]}]}]}
                                         {:workflowId "other"
                                          :steps [{:stepId "o1"
                                                   :operationId "other"
                                                   :parameters [{:name "why"
                                                                 :in "query"
                                                                 :value "$inputs.reason"}]}]}]}]
                    (arazzo.run-workflow doc "wf" {} {:api client} {})
                    (assert.are.same {:why 503} (. seen 2 2 :query)))))
            (it "send a querystring parameter as the whole query"
                (fn []
                  (let [(client seen) (recording-client {:op #(ok-resp {})})]
                    (arazzo.run-workflow (one-step-doc {:operationId "op"
                                                        :parameters [{:name "q"
                                                                      :in "querystring"
                                                                      :value "a=1&b={$inputs.b}"}]})
                                         "wf" {:b "x y"} {:api client} {})
                    (assert.are.equal "a=1&b=x y" (. seen 1 2 :querystring)))))
            (it "take a step's timeout in milliseconds"
                (fn []
                  (let [(client seen) (recording-client {:op #(ok-resp {})})]
                    (arazzo.run-workflow (one-step-doc {:operationId "op"
                                                        :timeout 1500})
                                         "wf" {} {:api client} {})
                    (assert.are.equal 1.5 (. seen 1 2 :timeout)))))
            (it "refuse a step that depends on a later step"
                (fn []
                  (let [(client) (recording-client {:op #(ok-resp {})})
                        doc {:arazzo "1.1.0"
                             :info {}
                             :workflows [{:workflowId "wf"
                                          :steps [{:stepId "a"
                                                   :operationId "op"
                                                   :dependsOn ["b"]}
                                                  {:stepId "b"
                                                   :operationId "op"}]}]}
                        (ok err) (pcall arazzo.run-workflow doc "wf" {}
                                        {:api client} {})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "depends on step 'b', which runs after it"
                                         1 true)))))
            (it "refuse AsyncAPI steps"
                (fn []
                  (let [(client) (recording-client {:op #(ok-resp {})})
                        (ok err) (pcall arazzo.run-workflow
                                        (one-step-doc {:operationId "op"
                                                       :action "send"})
                                        "wf" {} {:api client} {})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find "AsyncAPI" 1 true)))))
            (it "report conditions that can't be evaluated through :warn"
                (fn []
                  (let [(client) (recording-client {:op #(ok-resp {})})
                        warnings []
                        doc (one-step-doc {:operationId "op"})]
                    (set (. doc.workflows 1 :steps 1 :successCriteria)
                         [{:condition "$statuscode == 200"}])
                    (assert.is_false (pcall arazzo.run-workflow doc "wf" {}
                                            {:api client}
                                            {:warn #(table.insert warnings $)}))
                    (assert.are.equal 1 (length warnings)))))))

(describe "Arazzo documents"
          (fn []
            (it "load versions 1.0 and 1.1 only"
                (fn []
                  (each [version ok (pairs {"1.0.1" true
                                            "1.1.0" true
                                            "1.1.7" true
                                            "2.0.0" false
                                            "0.9" false})]
                    (let [file (.. (os.tmpname) ".json")]
                      (with-open [f (io.open file :w)]
                        (f:write (.. "{\"arazzo\":\"" version
                                     "\",\"info\":{},\"sourceDescriptions\":[],\"workflows\":[]}")))
                      (let [(loaded err) (pcall arazzo.load-doc file)]
                        (os.remove file)
                        (assert.are.equal ok loaded version)
                        (when (not ok)
                          (assert.is_truthy (: (tostring err) :find
                                               "not supported" 1 true))))))))
            (it "resolve sources against $self"
                (fn []
                  (let [doc {:arazzo "1.1.0"
                             ;; absolute: it is the base whatever the location
                             "$self" (.. (os.getenv "PWD")
                                         "/test/fixtures/flow.arazzo.json")
                             :info {}
                             :sourceDescriptions [{:name "pets"
                                                   :type "openapi"
                                                   :url "./petstore.yaml"}]
                             :workflows []}]
                    (assert.is_not_nil (. (arazzo.build-clients doc {}
                                                                "elsewhere/x.json")
                                          :pets)))))
            (it "leave AsyncAPI sources out of the clients"
                (fn []
                  (let [doc {:arazzo "1.1.0"
                             :info {}
                             :sourceDescriptions [{:name "events"
                                                   :type "asyncapi"
                                                   :url "./nowhere.yaml"}]
                             :workflows []}]
                    (assert.are.same {} (arazzo.build-clients doc {})))))))

(describe "workflows of other Arazzo documents"
          (fn []
            (local json (require :ezu.json))

            (fn tmp-dir [files]
              "A new directory holding files ({relative-path → table, as JSON})."
              (let [dir (os.tmpname)]
                (os.remove dir)
                (each [name content (pairs files)]
                  (let [path (.. dir "/" name)]
                    (os.execute (.. "mkdir -p '" (path:match "^(.*)/") "'"))
                    (with-open [f (io.open path :w)]
                      (f:write (json.encode content)))))
                dir))

            (fn arazzo-doc [sources workflows]
              {:arazzo "1.1.0"
               :info {:title "t" :version "1"}
               :sourceDescriptions sources
               : workflows})

            (local main-doc
                   (arazzo-doc [{:name "common"
                                 :url "lib/common.json"
                                 :type "arazzo"}]
                               [{:workflowId "w"
                                 :inputs {:type "object"
                                          :properties {:n {:type "integer"}}}
                                 :steps [{:stepId "s"
                                          :workflowId "$sourceDescriptions.common.echo"
                                          :parameters [{:name "n"
                                                        :value "$inputs.n"}]}]
                                 :outputs {:r "$steps.s.outputs.r"}}]))
            (local echo-doc
                   (arazzo-doc [{:name "api" :url "api.json" :type "openapi"}]
                               [{:workflowId "echo"
                                 :steps []
                                 :outputs {:r "$inputs.n"}}
                                {:workflowId "fetch"
                                 :steps [{:stepId "get"
                                          :operationId "getX"
                                          :outputs {:v "$response.body#/v"}}]
                                 :outputs {:v "$steps.get.outputs.v"}}]))
            (local api
                   {:openapi "3.0.0"
                    :info {:title "a" :version "1"}
                    :servers [{:url "https://{zone}.api.test"
                               :variables {:zone {:default "z1"}}}]
                    :paths {:/x {:get {:operationId "getX" :responses {}}}}})

            (fn run-in [dir workflow-id inputs ?opts]
              (let [(ok result) (pcall arazzo.run (.. dir "/main.json")
                                       workflow-id inputs ?opts)]
                (os.execute (.. "rm -rf '" dir "'"))
                (values ok result)))

            (it "runs a workflow of an Arazzo source, its outputs the step's"
                (fn []
                  (let [dir (tmp-dir {:main.json main-doc
                                      :lib/common.json echo-doc
                                      :lib/api.json api})
                        (ok result) (run-in dir "w" {:n 4})]
                    (assert.is_true ok result)
                    (assert.are.equal 4 result.outputs.r))))
            (it "runs it with its own document's sources and the run's options"
                (fn []
                  (let [doc (doto (arazzo-doc main-doc.sourceDescriptions
                                              [{:workflowId "w"
                                                :steps [{:stepId "s"
                                                         :workflowId "$sourceDescriptions.common.fetch"}]
                                                :outputs {:v "$steps.s.outputs.v"}}]))
                        dir (tmp-dir {:main.json doc
                                      :lib/common.json echo-doc
                                      :lib/api.json api})
                        urls []
                        (ok result) (run-in dir "w" {}
                                            {:server-vars {:zone "z9"}
                                             :http-fn (fn [req]
                                                        (table.insert urls
                                                                      req.url)
                                                        (ok-resp {:v 7}))})]
                    (assert.is_true ok result)
                    (assert.are.equal 7 result.outputs.v)
                    (assert.are.same ["https://z9.api.test/x"] urls))))
            (it "names the source and workflow when it fails"
                (fn []
                  (let [doc (arazzo-doc main-doc.sourceDescriptions
                                        [{:workflowId "w"
                                          :steps [{:stepId "s"
                                                   :workflowId "$sourceDescriptions.common.fetch"}]}])
                        failing (doto (arazzo-doc echo-doc.sourceDescriptions
                                                  [{:workflowId "fetch"
                                                    :steps [{:stepId "get"
                                                             :operationId "getX"
                                                             :successCriteria [{:condition "$statusCode == 200"}]}]}]))
                        dir (tmp-dir {:main.json doc
                                      :lib/common.json failing
                                      :lib/api.json api})
                        (ok err) (run-in dir "w" {}
                                         {:http-fn #(ok-resp {} 500)})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "step 's' (common.fetch) › step 'get' failed: $statusCode == 200"
                                         1 true)))))
            (it "goes to a workflow of an Arazzo source"
                (fn []
                  (let [doc (arazzo-doc main-doc.sourceDescriptions
                                        [{:workflowId "w"
                                          :steps [{:stepId "s"
                                                   :workflowId "$sourceDescriptions.common.echo"
                                                   :parameters [{:name "n"
                                                                 :value 1}]
                                                   :onSuccess [{:name "next"
                                                                :type "goto"
                                                                :workflowId "$sourceDescriptions.common.echo"
                                                                :parameters [{:name "n"
                                                                              :value 2}]}]}]}])
                        dir (tmp-dir {:main.json doc
                                      :lib/common.json echo-doc
                                      :lib/api.json api})
                        (ok result) (run-in dir "w" {})]
                    (assert.is_true ok result))))
            (it "stops a cycle across documents"
                (fn []
                  (let [doc (arazzo-doc [{:name "other"
                                          :url "other.json"
                                          :type "arazzo"}]
                                        [{:workflowId "w"
                                          :steps [{:stepId "s"
                                                   :workflowId "$sourceDescriptions.other.back"}]}])
                        other (arazzo-doc [{:name "main"
                                            :url "main.json"
                                            :type "arazzo"}]
                                          [{:workflowId "back"
                                            :steps [{:stepId "s"
                                                     :workflowId "$sourceDescriptions.main.w"}]}])
                        dir (tmp-dir {:main.json doc :other.json other})
                        (ok err) (run-in dir "w" {})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "workflow cycle: w -> other.back -> main.w"
                                         1 true)))))
            (it "says when a source isn't an Arazzo document or lacks the workflow"
                (fn []
                  (let [doc (arazzo-doc [{:name "api"
                                          :url "lib/api.json"
                                          :type "openapi"}
                                         {:name "common"
                                          :url "lib/common.json"
                                          :type "arazzo"}]
                                        [{:workflowId "a"
                                          :steps [{:stepId "s"
                                                   :workflowId "$sourceDescriptions.api.x"}]}
                                         {:workflowId "b"
                                          :steps [{:stepId "s"
                                                   :workflowId "$sourceDescriptions.common.nope"}]}])
                        files {:main.json doc
                               :lib/common.json echo-doc
                               :lib/api.json api}
                        (_ err-a) (run-in (tmp-dir files) "a" {})
                        (_ err-b) (run-in (tmp-dir files) "b" {})]
                    (assert.is_truthy (: (tostring err-a) :find
                                         "source 'api' is not an Arazzo document"
                                         1 true))
                    (assert.is_truthy (: (tostring err-b) :find
                                         "workflow not found: common.nope" 1
                                         true)))))
            (it "loads only sources next to the document unless sources are trusted"
                (fn []
                  (let [lib (tmp-dir {:common.json echo-doc :api.json api})
                        absolute (arazzo-doc [{:name "common"
                                               :url (.. lib "/common.json")
                                               :type "arazzo"}]
                                             main-doc.workflows)
                        remote (arazzo-doc [{:name "common"
                                             :url "https://elsewhere.test/common.json"
                                             :type "arazzo"}]
                                           main-doc.workflows)
                        elsewhere (doto (arazzo-doc main-doc.sourceDescriptions
                                                    main-doc.workflows)
                                    (tset "$self"
                                          "https://elsewhere.test/main.json"))
                        (_ err-abs) (run-in (tmp-dir {:main.json absolute}) "w"
                                            {:n 1})
                        (_ err-remote) (run-in (tmp-dir {:main.json remote})
                                               "w" {:n 1})
                        (_ err-self) (run-in (tmp-dir {:main.json elsewhere})
                                             "w" {:n 1})
                        (ok result) (run-in (tmp-dir {:main.json absolute}) "w"
                                            {:n 1} {:trust-sources true})]
                    (os.execute (.. "rm -rf '" lib "'"))
                    (each [_ err (ipairs [err-abs err-remote err-self])]
                      (assert.is_truthy (: (tostring err) :find
                                           "Arazzo source 'common' is not next to the document"
                                           1 true)))
                    (assert.is_true ok result)
                    (assert.are.equal 1 result.outputs.r))))
            (it "takes server variables any document's sources declare, and only those"
                (fn []
                  (let [own {:openapi "3.0.0"
                             :info {:title "o" :version "1"}
                             :servers [{:url "https://own.test"}]
                             :paths {:/o {:get {:operationId "getO"
                                                :responses {}}}}}
                        doc (arazzo-doc [{:name "own"
                                          :url "own.json"
                                          :type "openapi"}
                                         {:name "common"
                                          :url "lib/common.json"
                                          :type "arazzo"}]
                                        [{:workflowId "w"
                                          :steps [{:stepId "s"
                                                   :workflowId "$sourceDescriptions.common.fetch"}]
                                          :outputs {:v "$steps.s.outputs.v"}}])
                        files {:main.json doc
                               :own.json own
                               :lib/common.json echo-doc
                               :lib/api.json api}
                        urls []
                        http-fn (fn [req]
                                  (table.insert urls req.url)
                                  (ok-resp {:v 7}))
                        (ok result) (run-in (tmp-dir files) "w" {}
                                            {:server-vars {:zone "z9"}
                                             : http-fn})
                        (ok2 err2) (run-in (tmp-dir files) "w" {}
                                           {:server-vars {:zoen "z9"}
                                            : http-fn})]
                    (assert.is_true ok result)
                    (assert.are.same ["https://z9.api.test/x"] urls)
                    (assert.is_false ok2)
                    (assert.is_truthy (: (tostring err2) :find
                                         "no openapi source declares server variable 'zoen'"
                                         1 true)
                                      (tostring err2))
                    (assert.are.equal 1 (length urls)))))
            (it "applies base-url to the first document's API only"
                (fn []
                  (let [own {:openapi "3.0.0"
                             :info {:title "o" :version "1"}
                             :servers [{:url "https://own.test"}]
                             :paths {:/o {:get {:operationId "getO"
                                                :responses {}}}}}
                        doc (arazzo-doc [{:name "own"
                                          :url "own.json"
                                          :type "openapi"}
                                         {:name "common"
                                          :url "lib/common.json"
                                          :type "arazzo"}]
                                        [{:workflowId "w"
                                          :steps [{:stepId "o"
                                                   :operationId "getO"}
                                                  {:stepId "s"
                                                   :workflowId "$sourceDescriptions.common.fetch"}]}])
                        urls []
                        (ok result) (run-in (tmp-dir {:main.json doc
                                                      :own.json own
                                                      :lib/common.json echo-doc
                                                      :lib/api.json api})
                                            "w" {}
                                            {:base-url "http://localhost:9999"
                                             :http-fn (fn [req]
                                                        (table.insert urls
                                                                      req.url)
                                                        (ok-resp {:v 7}))})]
                    (assert.is_true ok result)
                    (assert.are.same ["http://localhost:9999/o"
                                      "https://z1.api.test/x"]
                                     urls))))
            (it "says where a source refused through $self resolves"
                (fn []
                  (let [elsewhere (doto (arazzo-doc main-doc.sourceDescriptions
                                                    main-doc.workflows)
                                    (tset "$self"
                                          "https://elsewhere.test/main.json"))
                        (_ err) (run-in (tmp-dir {:main.json elsewhere}) "w"
                                        {:n 1})]
                    (assert.is_truthy (: (tostring err) :find
                                         "(lib/common.json, at https://elsewhere.test/lib/common.json)"
                                         1 true)
                                      (tostring err)))))
            (it "fails the run on a document problem, whatever the actions say"
                (fn []
                  (let [doc (arazzo-doc [{:name "common"
                                          :url "https://elsewhere.test/c.json"
                                          :type "arazzo"}
                                         {:name "bad" :url 5 :type "arazzo"}]
                                        [{:workflowId "w"
                                          :steps [{:stepId "s"
                                                   :workflowId "$sourceDescriptions.common.echo"
                                                   :onFailure [{:name "ignore"
                                                                :type "end"}]}]}
                                         {:workflowId "missing"
                                          :steps [{:stepId "s"
                                                   :workflowId "$sourceDescriptions.nope.echo"
                                                   :onFailure [{:name "again"
                                                                :type "retry"
                                                                :retryLimit 3}]}]}
                                         {:workflowId "url"
                                          :steps [{:stepId "s"
                                                   :workflowId "$sourceDescriptions.bad.echo"}]}])
                        (ok err) (run-in (tmp-dir {:main.json doc}) "w" {})
                        (ok2 err2) (run-in (tmp-dir {:main.json doc}) "missing"
                                           {})
                        (_ err3) (run-in (tmp-dir {:main.json doc}) "url" {})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "step 's' (common.echo) › Arazzo source 'common' is not next to the document"
                                         1 true)
                                      (tostring err))
                    (assert.is_false ok2)
                    (assert.is_truthy (: (tostring err2) :find
                                         "unknown source 'nope'" 1 true))
                    (assert.is_truthy (: (tostring err3) :find
                                         "source 'bad': its url must be a string"
                                         1 true)
                                      (tostring err3)))))
            (it "says why a source can't be read, without where in ezu"
                (fn []
                  (let [(_ err) (run-in (tmp-dir {:main.json main-doc}) "w"
                                        {:n 1})]
                    (assert.is_truthy (: (tostring err) :find "common" 1 true))
                    (assert.is_nil (: (tostring err) :find "%.lua:%d+:")
                                   (tostring err)))))
            (it "stops workflows nested too deep"
                (fn []
                  (let [files {}]
                    (for [i 0 70]
                      (tset files (.. "d" i ".json")
                            (arazzo-doc [{:name "next"
                                          :url (.. "d" (+ i 1) ".json")
                                          :type "arazzo"}]
                                        [{:workflowId "w"
                                          :steps (if (< i 70)
                                                     [{:stepId "s"
                                                       :workflowId "$sourceDescriptions.next.w"}]
                                                     [])}])))
                    (tset files :main.json (. files :d0.json))
                    (let [(ok err) (run-in (tmp-dir files) "w" {})]
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find
                                           "workflows nested more than 64 deep"
                                           1 true)
                                        (tostring err))))))
            (it "knows its own document under any path to it"
                (fn []
                  (let [doc (arazzo-doc [{:name "other"
                                          :url "other.json"
                                          :type "arazzo"}]
                                        [{:workflowId "w"
                                          :steps [{:stepId "s"
                                                   :workflowId "$sourceDescriptions.other.back"}]}])
                        other (arazzo-doc [{:name "main"
                                            :url "main.json"
                                            :type "arazzo"}]
                                          [{:workflowId "back"
                                            :steps [{:stepId "s"
                                                     :workflowId "$sourceDescriptions.main.w"}]}])
                        dir "build/cross-doc-path"]
                    (os.execute (.. "mkdir -p " dir))
                    (each [name t (pairs {:main.json doc :other.json other})]
                      (with-open [f (io.open (.. dir "/" name) :w)]
                        (f:write (json.encode t))))
                    (let [(ok err) (pcall arazzo.run
                                          (.. "./" dir "/./main.json") "w" {})]
                      (os.execute (.. "rm -rf " dir))
                      (assert.is_false ok)
                      (let [expected "workflow cycle: w -> other.back -> main.w"]
                        (assert.are.equal expected
                                          (: (tostring err) :sub
                                             (- (length expected)))))))))
            (it "names another document's workflow by its source in progress events"
                (fn []
                  (let [seen []
                        dir (tmp-dir {:main.json main-doc
                                      :lib/common.json echo-doc
                                      :lib/api.json api})
                        (ok result) (run-in dir "w" {:n 2}
                                            {:on-step #(table.insert seen
                                                                     $.workflow)})]
                    (assert.is_true ok result)
                    (assert.is_truthy (accumulate [found false _ w (ipairs seen)]
                                        (or found (= w "common.echo")))
                                      (table.concat seen ",")))))))
