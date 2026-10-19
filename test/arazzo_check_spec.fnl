;; ABOUTME: Specs for checking Arazzo documents before running them: targets,
;; ABOUTME: parameters, bodies, references, conditions and actions.
(local check (require :ezu.arazzo.check))

(fn op [id ?fields]
  (doto {:operation-id id
         :method "get"
         :path-params []
         :parameters []
         :has-body false
         :spec {}
         :url-for #""
         :invoke #{}}
    (#(each [k v (pairs (or ?fields {}))]
        (tset $ k v)))))

(local clients
       {:api {:get-pet (op "get-pet"
                           {:path-params ["id"]
                            :parameters [{:name "id" :in "path" :required true}
                                         {:name "fields" :in "query"}
                                         {:name "x-trace"
                                          :in "header"
                                          :required true}]})
              :add-pet (op "add-pet"
                           {:method "post"
                            :has-body true
                            :spec {:requestBody {:required true}}})}})

(fn doc [steps ?wf ?extra]
  (doto {:arazzo "1.1.0"
         :info {}
         :workflows [(doto {:workflowId "wf"
                            :inputs {:type "object"
                                     :properties {:id {:type "string"}}}
                            : steps}
                       (#(each [k v (pairs (or ?wf {}))]
                           (tset $ k v))))]}
    (#(each [k v (pairs (or ?extra {}))]
        (tset $ k v)))))

(local get-pet {:stepId "get"
                :operationId "get-pet"
                :parameters [{:name "id" :in "path" :value "$inputs.id"}
                             {:name "x-trace" :in "header" :value "t"}]
                :successCriteria [{:condition "$statusCode == 200"}]
                :outputs {:name "$response.body#/name"}})

(fn step [fields]
  (collect [k v (pairs (doto (collect [k v (pairs get-pet)] k v)
                         (#(each [k v (pairs fields)]
                             (tset $ k v)))))]
    k
    v))

(fn messages [problems ?level]
  (icollect [_ p (ipairs problems)]
    (when (or (= nil ?level) (= p.level ?level))
      (.. p.where ": " p.message))))

(fn has [problems text ?level]
  (accumulate [found false _ m (ipairs (messages problems ?level))]
    (or found (not= nil (m:find text 1 true)))))

(describe "arazzo check"
          (fn []
            (it "finds nothing wrong in a correct document"
                (fn []
                  (assert.are.same []
                                   (messages (check.check (doc [get-pet
                                                                {:stepId "add"
                                                                 :operationId "add-pet"
                                                                 :requestBody {:payload {:name "$steps.get.outputs.name"}}}]
                                                               {:outputs {:pet "$steps.get.outputs.name"}})
                                                          clients)))))
            (it "finds operations that don't exist"
                (fn []
                  (assert.is_true (has (check.check (doc [(step {:operationId "get-pets"})])
                                                    clients)
                                       "wf › step get: operation not found: get-pets"
                                       :error))))
            (it "finds steps that call nothing, or several things"
                (fn []
                  (assert.is_true (has (check.check (doc [{:stepId "s"}])
                                                    clients)
                                       "step s: calls nothing" :error))
                  (assert.is_true (has (check.check (doc [(step {:workflowId "wf"})])
                                                    clients)
                                       "step get: calls both" :error))))
            (it "finds ids used twice"
                (fn []
                  (assert.is_true (has (check.check (doc [get-pet get-pet])
                                                    clients)
                                       "step get: stepId used twice" :error))))
            (it "finds missing required parameters, and parameters the operation doesn't declare"
                (fn []
                  (let [problems (check.check (doc [(step {:parameters [{:name "id"
                                                                         :in "path"
                                                                         :value 1}
                                                                        {:name "colour"
                                                                         :in "query"
                                                                         :value "red"}]})])
                                              clients)]
                    (assert.is_true (has problems
                                         "step get: required header parameter 'x-trace' is missing"
                                         :error))
                    (assert.is_true (has problems
                                         "step get: get-pet has no query parameter 'colour'"
                                         :warning)))))
            (it "finds parameters without a valid location"
                (fn []
                  (assert.is_true (has (check.check (doc [(step {:parameters [{:name "id"
                                                                               :in "body"
                                                                               :value 1}]})])
                                                    clients)
                                       "parameter 'id': 'in' must be path, query, header, cookie or querystring"
                                       :error))))
            (it "finds bodies missing or not expected"
                (fn []
                  (assert.is_true (has (check.check (doc [{:stepId "add"
                                                           :operationId "add-pet"}])
                                                    clients)
                                       "step add: add-pet requires a request body"
                                       :error))
                  (assert.is_true (has (check.check (doc [(step {:requestBody {:payload {}}})])
                                                    clients)
                                       "step get: get-pet takes no request body"
                                       :warning))))
            (it "finds references to steps, outputs, inputs and workflows that don't exist"
                (fn []
                  (let [problems (check.check (doc [(step {:outputs {:a "$steps.nope.outputs.x"
                                                                     :b "$steps.get.outputs.nmae"
                                                                     :c "$inputs.idd"
                                                                     :d "$workflows.other.outputs.x"
                                                                     :e "Hi {$inputs.who}"}})])
                                              clients)]
                    (assert.is_true (has problems "unknown step 'nope'" :error))
                    (assert.is_true (has problems
                                         "step 'get' has no output 'nmae'"
                                         :error))
                    (assert.is_true (has problems "no input 'idd'" :error))
                    (assert.is_true (has problems "no input 'who'" :error))
                    (assert.is_true (has problems "unknown workflow 'other'"
                                         :error)))))
            (it "finds runtime expressions it doesn't know"
                (fn []
                  (assert.is_true (has (check.check (doc [(step {:outputs {:a "$statuscode"}})])
                                                    clients)
                                       "unknown runtime expression: $statuscode"
                                       :error))))
            (it "finds conditions, regexes and JSONPath queries that can't be evaluated"
                (fn []
                  (let [problems (check.check (doc [(step {:successCriteria [{:condition "$statusCode =="}
                                                                             {:condition "(a"
                                                                              :context "$statusCode"
                                                                              :type "regex"}
                                                                             {:condition "$[?"
                                                                              :context "$response.body"
                                                                              :type "jsonpath"}
                                                                             {:condition "^{$inputs.id}$"
                                                                              :context "$statusCode"
                                                                              :type "regex"}]})])
                                              clients)]
                    (assert.is_true (has problems "unexpected end in condition"
                                         :error))
                    (assert.is_true (has problems "invalid regular expression"
                                         :error))
                    (assert.is_true (has problems "invalid JSONPath query"
                                         :error))
                    ;; runtime expressions inside: only known when running
                    (assert.are.equal 3 (length (messages problems :error))))))
            (it "finds actions going nowhere"
                (fn []
                  (let [problems (check.check (doc [(step {:onFailure [{:name "poll"
                                                                        :type "goto"
                                                                        :stepId "wiat"}
                                                                       {:name "odd"
                                                                        :type "jump"}
                                                                       {:name "sub"
                                                                        :type "goto"
                                                                        :workflowId "nope"}]})])
                                              clients)]
                    (assert.is_true (has problems
                                         "step get › onFailure poll: goto to unknown step 'wiat'"
                                         :error))
                    (assert.is_true (has problems
                                         "onFailure odd: type must be end, goto or retry"
                                         :error))
                    (assert.is_true (has problems "unknown workflow 'nope'"
                                         :error)))))
            (it "finds workflows that depend on or call workflows that don't exist"
                (fn []
                  (assert.is_true (has (check.check (doc [get-pet]
                                                         {:dependsOn ["setup"]})
                                                    clients)
                                       "wf: depends on unknown workflow 'setup'"
                                       :error))
                  (assert.is_true (has (check.check (doc [{:stepId "call"
                                                           :workflowId "nope"}])
                                                    clients)
                                       "step call: unknown workflow 'nope'"
                                       :error))))
            (it "matches header parameters whatever their case, and leaves out the ones OpenAPI ignores"
                (fn []
                  (let [ops {:api {:get-pet (op "get-pet"
                                                {:path-params ["id"]
                                                 :parameters [{:name "id"
                                                               :in "path"
                                                               :required true}
                                                              {:name "X-Trace"
                                                               :in "header"
                                                               :required true}
                                                              {:name "Authorization"
                                                               :in "header"
                                                               :required true}
                                                              {:name "Accept"
                                                               :in "header"
                                                               :required true}]})}}]
                    (assert.are.same []
                                     (messages (check.check (doc [(step {:parameters [{:name "id"
                                                                                       :in "path"
                                                                                       :value 1}
                                                                                      {:name "x-trace"
                                                                                       :in "header"
                                                                                       :value "t"}]})])
                                                            ops))))))
            (it "counts the parameters the profile supplies"
                (fn []
                  (assert.are.same []
                                   (messages (check.check (doc [(step {:parameters [{:name "id"
                                                                                     :in "path"
                                                                                     :value 1}]})])
                                                          clients
                                                          {:header {:x-trace true}
                                                           :query {}})))))
            (it "reports malformed documents instead of failing"
                (fn []
                  (each [_ [steps text] (ipairs [[[{:operationId "get-pet"}]
                                                  "needs a stepId"]
                                                 ["x" "steps must be a list"]
                                                 [["hello"]
                                                  "steps must be a list"]
                                                 [[{:stepId "s" :workflowId 3}]
                                                  "workflowId must be a string"]
                                                 [[{:stepId "s"
                                                    :operationPath 12}]
                                                  "operationPath must be a string"]])]
                    (let [(ok problems) (pcall check.check (doc steps) clients)]
                      (assert.is_true ok (tostring problems))
                      (assert.is_true (has problems text :error) text)))
                  (let [(ok problems) (pcall check.check
                                             (doc [get-pet] {:dependsOn [3]})
                                             clients)]
                    (assert.is_true ok (tostring problems))
                    (assert.is_true (has problems
                                         "dependsOn must list workflow ids"
                                         :error)))))
            (it "doesn't take text in quotes for expressions"
                (fn []
                  (assert.are.same []
                                   (messages (check.check (doc [(step {:successCriteria [{:condition "$response.body#/note == 'costs $5'"}]})])
                                                          clients)))))
            (it "follows workflows of other Arazzo documents"
                (fn []
                  (let [json (require :ezu.json)
                        dir "build/check-sources"
                        other {:arazzo "1.1.0"
                               :info {}
                               :workflows [{:workflowId "ow"
                                            :steps []
                                            :outputs {:res "$inputs.id"}}
                                           {:workflowId "broken"
                                            :steps [{:stepId "s"
                                                     :workflowId "missing"}]}]}
                        sources {:sourceDescriptions [{:name "other"
                                                       :type "arazzo"
                                                       :url (.. dir
                                                                "/other.json")}]}
                        check-steps #(check.check (doc $1 $2 sources) clients
                                                  {} {})]
                    (os.execute (.. "mkdir -p " dir))
                    (with-open [f (io.open (.. dir "/other.json") :w)]
                      (f:write (json.encode other)))
                    (let [fine (check-steps [{:stepId "call"
                                              :workflowId "$sourceDescriptions.other.ow"}]
                                            {:outputs {:x "$steps.call.outputs.res"}
                                             :dependsOn ["$sourceDescriptions.other.ow"]})
                          wrong (check-steps [{:stepId "call"
                                               :workflowId "$sourceDescriptions.other.nope"}
                                              {:stepId "out"
                                               :workflowId "$sourceDescriptions.other.ow"}]
                                             {:outputs {:x "$steps.out.outputs.zzz"}})
                          far (check.check (doc [{:stepId "call"
                                                  :workflowId "$sourceDescriptions.other.ow"}]
                                                nil
                                                {:sourceDescriptions [{:name "other"
                                                                       :type "arazzo"
                                                                       :url "https://elsewhere.test/other.json"}]})
                                           clients {} {})]
                      (os.execute (.. "rm -rf " dir))
                      ;; the other document's own problems, under its name
                      (assert.are.same ["other › broken › step s: unknown workflow 'missing'"]
                                       (messages fine))
                      (assert.are.equal "other" (. fine 1 :document))
                      (assert.is_true (has wrong
                                           "wf › step call: source 'other' has no workflow 'nope'"
                                           :error))
                      (assert.is_true (has wrong
                                           "wf: step 'out' has no output 'zzz'"
                                           :error))
                      (assert.is_true (has far
                                           "wf › step call: Arazzo source 'other' is not next to the document"
                                           :error))))))
            (it "checks the confirmation question"
                (fn []
                  (assert.is_true (has (check.check (doc [] {:x-ezu-confirm 5})
                                                    clients)
                                       "wf: x-ezu-confirm must be a question (a string)"
                                       :error))
                  (assert.is_true (has (check.check (doc []
                                                         {:x-ezu-confirm "Delete {$inputs.nope}?"})
                                                    clients)
                                       "wf: no input 'nope' in workflow wf"
                                       :error))))
            (it "checks what lists an input's values"
                (fn []
                  (let [with-complete #(doc []
                                            {:inputs {:type "object"
                                                      :properties {:id {:type "string"
                                                                        :x-ezu-complete $}}}})]
                    (assert.is_true (has (check.check (with-complete {:workflowId "nope"
                                                                      :selector "$[*]"})
                                                      clients)
                                         "wf: input id: x-ezu-complete names unknown workflow 'nope'"
                                         :error))
                    (assert.is_true (has (check.check (with-complete {:workflowId "wf"
                                                                      :selector "$[?"})
                                                      clients)
                                         "wf: input id: x-ezu-complete selector"
                                         :error))
                    (assert.is_true (has (check.check (with-complete "wf")
                                                      clients)
                                         "wf: input id: x-ezu-complete must be an object with a workflowId and a selector"
                                         :error))
                    (assert.are.same []
                                     (messages (check.check (with-complete {:workflowId "wf"
                                                                            :selector "$.ids[*]"})
                                                            clients))))))
            (it "leaves the options it is given as they are"
                (fn []
                  (let [opts {:trust-sources false}]
                    (check.check (doc [{:stepId "call"
                                        :workflowId "$sourceDescriptions.other.ow"}]
                                      nil
                                      {:sourceDescriptions [{:name "other"
                                                             :type "arazzo"
                                                             :url "build/nowhere/o.json"}]})
                                 clients {} opts)
                    (assert.are.same {:trust-sources false} opts))))
            (it "checks command words, and the documents sources mount"
                (fn []
                  (let [json (require :ezu.json)
                        dir "build/check-mounts"
                        mounted {:arazzo "1.1.0"
                                 :info {}
                                 :workflows [{:workflowId "a"
                                              :x-ezu-command "one"
                                              :steps []}
                                             {:workflowId "b"
                                              :x-ezu-command "one"
                                              :steps []}]}
                        index (doc [] {:x-ezu-command "  "}
                                   {:sourceDescriptions [{:name "sub"
                                                          :type "arazzo"
                                                          :url (.. dir
                                                                   "/sub.json")
                                                          :x-ezu-command "sub"}]})]
                    (os.execute (.. "mkdir -p " dir))
                    (with-open [f (io.open (.. dir "/sub.json") :w)]
                      (f:write (json.encode mounted)))
                    (let [problems (check.check index clients {} {})]
                      (os.execute (.. "rm -rf " dir))
                      (assert.are.same ["wf: x-ezu-command must be words, like \"instance create\""
                                        "sub › b: x-ezu-command 'one' is also workflow a's"]
                                       (messages problems))))))
            (it "reports a workflow's own actions once"
                (fn []
                  (let [problems (check.check (doc [get-pet
                                                    (step {:stepId "again"})]
                                                   {:failureActions [{:name "bad"
                                                                      :type "goto"
                                                                      :stepId "nope"}]})
                                              clients)]
                    (assert.are.same ["wf › failureActions bad: goto to unknown step 'nope'"]
                                     (messages problems)))))
            (it "finds positional arguments that aren't inputs"
                (fn []
                  (let [problems (check.check (doc [get-pet]
                                                   {:x-ezu-args ["id"
                                                                 "nope"
                                                                 "id"]})
                                              clients)]
                    (assert.is_true (has problems
                                         "wf: x-ezu-args names 'nope', which isn't an input"
                                         :error))
                    (assert.is_true (has problems
                                         "wf: x-ezu-args names 'id' twice"
                                         :error)))))
            (it "finds references to components that don't exist"
                (fn []
                  (assert.is_true (has (check.check (doc [(step {:parameters [{:reference "$components.parameters.trace"}]})])
                                                    clients)
                                       "unknown component $components.parameters.trace"
                                       :error))))))
