;; ABOUTME: Specs for the MCP server: tool definitions built from operations,
;; ABOUTME: OpenAPI schemas as JSON Schema 2020-12, and the JSON-RPC handling.
(local mcp (require :ezu.cli.mcp))
(local ezu (require :ezu))
(local json (require :ezu.json))

(describe "mcp.json-schema"
          (fn []
            (it "turns OpenAPI 3.0 nullable into a null type"
                (fn []
                  (assert.are.same {:type [:string :null]}
                                   (mcp.json-schema {:type :string
                                                     :nullable true}
                                                    true))
                  (assert.are.same {:type [:string :null]
                                    :enum ["a" json.null]}
                                   (mcp.json-schema {:type :string
                                                     :enum ["a"]
                                                     :nullable true}
                                                    true))))
            (it "turns OpenAPI 3.0 boolean exclusive bounds into numbers"
                (fn []
                  (assert.are.same {:type :integer
                                    :exclusiveMinimum 0
                                    :maximum 9}
                                   (mcp.json-schema {:type :integer
                                                     :minimum 0
                                                     :exclusiveMinimum true
                                                     :maximum 9
                                                     :exclusiveMaximum false}
                                                    true))))
            (it "converts nested schemas but not data"
                (fn []
                  (assert.are.same {:type :object
                                    :properties {:a {:type [:integer :null]}}
                                    :items {:anyOf [{:type [:string :null]}]}
                                    :example {:nullable true}}
                                   (mcp.json-schema {:type :object
                                                     :properties {:a {:type :integer
                                                                      :nullable true}}
                                                     :items {:anyOf [{:type :string
                                                                      :nullable true}]}
                                                     :example {:nullable true}}
                                                    true))))
            (it "leaves OpenAPI 3.1 schemas as they are"
                (fn []
                  (assert.are.same {:type :string :nullable true}
                                   (mcp.json-schema {:type :string
                                                     :nullable true}
                                                    false))))
            (it "writes recursive schemas with local $defs"
                (fn []
                  (let [node {:type :object :properties {}}]
                    (set node.properties.child node)
                    (let [out (mcp.json-schema node false)
                          ;; encodable: no cycles left
                          text (json.encode out)]
                      (assert.is_truthy text)
                      (assert.are.equal "#/$defs/s1"
                                        (. out :properties :child "$ref"))
                      (assert.are.equal "#/$defs/s1"
                                        (. out "$defs" :s1 :properties :child
                                           "$ref"))))))))

(describe "mcp.json-schema on the rest of JSON Schema"
          (fn []
            (it "converts contentSchema and dependencies, and survives cycles there"
                (fn []
                  (let [node {:type :object :properties {}}]
                    (set node.properties.s {:type :string :contentSchema node})
                    (set node.dependencies {:x node :y ["z"]})
                    (set node.x-self node)
                    (let [out (mcp.json-schema node false)]
                      (assert.is_truthy (json.encode out))
                      (assert.are.equal "#/$defs/s1"
                                        (. out :properties :s :contentSchema
                                           "$ref"))
                      ;; draft-07 dependencies, as 2020-12 has them
                      (assert.is_nil out.dependencies)
                      (assert.are.equal "#/$defs/s1"
                                        (. out :dependentSchemas :x "$ref"))
                      (assert.are.same ["z"] (. out :dependentRequired :y))))))
            (it "leaves out $id, $anchor and $schema, which would move $defs"
                (fn []
                  (let [node {"$id" "https://example.com/node"
                              "$schema" "https://json-schema.org/draft/2020-12/schema"
                              :type :object
                              :properties {:a {"$anchor" "a" :type :string}}}]
                    (assert.are.same {:type :object
                                      :properties {:a {:type :string}}}
                                     (mcp.json-schema node false)))))
            (it "lets OpenAPI 3.0 nullable without a type allow null"
                (fn []
                  (assert.are.same {:anyOf [{:allOf [{:type :object}]}
                                            {:type :null}]}
                                   (mcp.json-schema {:nullable true
                                                     :allOf [{:type :object}]}
                                                    true))))
            (it "leaves read-only properties out of request bodies"
                (fn []
                  (assert.are.same {:type :object
                                    :required ["name"]
                                    :properties {:name {:type :string}}}
                                   (mcp.json-schema {:type :object
                                                     :required ["id" "name"]
                                                     :properties {:id {:type :string
                                                                       :readOnly true}
                                                                  :name {:type :string}}}
                                                    false nil true))))))

(local api
       {:openapi "3.0.3"
        :info {:title "Pets" :version "1"}
        :servers [{:url "https://api.test"}]
        :paths {"/pets/{petId}" {:parameters [{:name "petId"
                                               :in "path"
                                               :required true
                                               :description "The pet"
                                               :schema {:type :integer}}]
                                 :get {:operationId "getPet"
                                       :summary "Get a pet"
                                       :description "Returns one pet."
                                       :parameters [{:name "fields"
                                                     :in "query"
                                                     :schema {:type :array
                                                              :items {:type :string}}}
                                                    {:name "X-Org"
                                                     :in "header"
                                                     :required true
                                                     :schema {:type :string}}
                                                    {:name "session"
                                                     :in "cookie"
                                                     :schema {:type :string}}]}
                                 :put {:operationId "replacePet"
                                       :requestBody {:required true
                                                     :content {:application/json {:schema {:type :object
                                                                                           :properties {:name {:type :string
                                                                                                               :nullable true}}}}}}}
                                 :delete {:operationId "deletePet"}}
                "/pets" {:post {:operationId "addPet"
                                :parameters [{:name "petId"
                                              :in "query"
                                              :schema {:type :string}}]}}}})

(local client (ezu.client api {:http-fn #nil}))

(describe "mcp.tool"
          (fn []
            (it "describes a read-only operation"
                (fn []
                  (let [t (mcp.tool client.get-pet {:openapi-30 true})]
                    (assert.are.equal "get-pet" t.name)
                    (assert.are.equal "Get a pet" t.title)
                    (assert.are.equal "GET /pets/{petId}\n\nGet a pet\n\nReturns one pet."
                                      t.description)
                    (assert.are.same {:readOnlyHint true
                                      :destructiveHint false
                                      :idempotentHint true
                                      :openWorldHint true}
                                     t.annotations)
                    (assert.are.same {:type :object
                                      :additionalProperties false
                                      :properties {:petId {:type :integer
                                                           :description "The pet"}
                                                   :fields {:type :array
                                                            :items {:type :string}}
                                                   :X-Org {:type :string}}
                                      :required ["X-Org" "petId"]}
                                     t.inputSchema))))
            (it "leaves out parameters ezu supplies"
                (fn []
                  (let [t (mcp.tool client.get-pet
                                    {:openapi-30 true
                                     :supplied-headers {:x-org true}})]
                    (assert.is_nil (. t.inputSchema.properties :X-Org))
                    (assert.are.same ["petId"] t.inputSchema.required))))
            (it "takes the body as body, converted"
                (fn []
                  (let [t (mcp.tool client.replace-pet {:openapi-30 true})]
                    (assert.are.same {:type :object
                                      :properties {:name {:type [:string :null]}}}
                                     t.inputSchema.properties.body)
                    (assert.are.same ["body" "petId"] t.inputSchema.required)
                    (assert.are.same {:readOnlyHint false
                                      :destructiveHint true
                                      :idempotentHint true
                                      :openWorldHint true}
                                     t.annotations))))
            (it "marks creations and names a parameter by its location when another has its name"
                (fn []
                  (let [t (mcp.tool client.add-pet {:openapi-30 true})]
                    (assert.are.same {:type :string}
                                     (. t.inputSchema.properties :petId))
                    (assert.are.same {:readOnlyHint false
                                      :destructiveHint false
                                      :idempotentHint false
                                      :openWorldHint true}
                                     t.annotations))
                  (let [op (ezu.client {:openapi "3.1.0"
                                        :info {}
                                        :servers [{:url "https://h"}]
                                        :paths {"/x/{id}" {:get {:operationId "getX"
                                                                 :parameters [{:name "id"
                                                                               :in "path"
                                                                               :required true}
                                                                              {:name "id"
                                                                               :in "query"}]}}}}
                                       {:http-fn #nil})
                        t (mcp.tool op.get-x {})]
                    (assert.is_truthy (. t.inputSchema.properties :id))
                    (assert.is_truthy (. t.inputSchema.properties "query.id")))))))

(describe "mcp.request"
          (fn []
            (it "maps arguments to path, query, headers and body"
                (fn []
                  (assert.are.same {:path {:petId 7}
                                    :query {:fields ["a"]}
                                    :headers {:X-Org "o"}
                                    :body nil}
                                   (mcp.request client.get-pet
                                                {:petId 7
                                                 :fields ["a"]
                                                 :X-Org "o"}))
                  (assert.are.same {:path {:petId 1}
                                    :query nil
                                    :headers nil
                                    :body {:name "Rex"}}
                                   (mcp.request client.replace-pet
                                                {:petId 1 :body {:name "Rex"}}))))
            (it "sends a JSON body that isn't an object as JSON"
                (fn []
                  (assert.are.equal "\"x\""
                                    (. (mcp.request client.replace-pet
                                                    {:petId 1 :body "x"})
                                       :body))
                  (assert.are.equal "null"
                                    (. (mcp.request client.replace-pet
                                                    {:petId 1 :body json.null})
                                       :body))))
            (it "checks required arguments and parameter values"
                (fn []
                  (each [_ [args message] (ipairs [[{:X-Org "o"}
                                                    "missing required argument: petId"]
                                                   [{:petId "7" :X-Org "o"}
                                                    "petId: expected integer"]
                                                   [{:petId 7
                                                     :X-Org "o"
                                                     :fields "a"}
                                                    "fields: expected array"]])]
                    (let [(ok err) (pcall mcp.request client.get-pet args)]
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find message 1 true))))
                  (let [(ok err) (pcall mcp.request client.replace-pet
                                        {:petId 1})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "missing required argument: body" 1
                                         true)))))
            (it "rejects arguments the tool doesn't take"
                (fn []
                  (let [(ok err) (pcall mcp.request client.get-pet
                                        {:petId 7 :nope 1})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "unknown argument: nope" 1 true)))))))

(local modern {"io.modelcontextprotocol/protocolVersion" "2026-07-28"
               "io.modelcontextprotocol/clientCapabilities" {}})

(fn make-handler []
  (let [calls []]
    (values (mcp.handler {:tools [{:name "t" :inputSchema {:type :object}}]
                          :call (fn [name arguments]
                                  (table.insert calls [name arguments])
                                  {:content [{:type :text :text "ok"}]
                                   :isError false})
                          :version "1.2.3"
                          :instructions "Use it."}) calls)))

(describe "mcp.handler"
          (fn []
            (it "answers server/discover"
                (fn []
                  (assert.are.same {:jsonrpc "2.0"
                                    :id 1
                                    :result {:resultType :complete
                                             :supportedVersions ["2026-07-28"]
                                             :capabilities {:tools {}}
                                             :instructions "Use it."
                                             :ttlMs 0
                                             :cacheScope :private
                                             :_meta {"io.modelcontextprotocol/serverInfo" {:name "ezu"
                                                                                           :version "1.2.3"}}}}
                                   ((make-handler) {:jsonrpc "2.0"
                                                    :id 1
                                                    :method "server/discover"
                                                    :params {:_meta modern}}))))
            (it "lists and calls tools"
                (fn []
                  (let [(handle calls) (make-handler)]
                    (assert.are.same [{:name "t" :inputSchema {:type :object}}]
                                     (. (handle {:jsonrpc "2.0"
                                                 :id 2
                                                 :method "tools/list"
                                                 :params {:_meta modern}})
                                        :result :tools))
                    (let [r (handle {:jsonrpc "2.0"
                                     :id "c"
                                     :method "tools/call"
                                     :params {:_meta modern
                                              :name "t"
                                              :arguments {:a 1}}})]
                      (assert.are.equal "c" r.id)
                      (assert.are.equal :complete r.result.resultType)
                      (assert.are.same [{:type :text :text "ok"}]
                                       r.result.content)
                      (assert.are.same [["t" {:a 1}]] calls)))))
            (it "rejects unknown tools and methods"
                (fn []
                  (let [handle (make-handler)]
                    (assert.are.same {:code -32602
                                      :message "Unknown tool: nope"}
                                     (. (handle {:jsonrpc "2.0"
                                                 :id 3
                                                 :method "tools/call"
                                                 :params {:_meta modern
                                                          :name "nope"}})
                                        :error))
                    (assert.are.equal -32601
                                      (. (handle {:jsonrpc "2.0"
                                                  :id 4
                                                  :method "resources/list"
                                                  :params {:_meta modern}})
                                         :error :code)))))
            (it "rejects unsupported versions, listing the supported ones"
                (fn []
                  (assert.are.same {:code -32022
                                    :message "Unsupported protocol version"
                                    :data {:supported ["2026-07-28"
                                                       "2025-11-25"
                                                       "2025-06-18"
                                                       "2025-03-26"
                                                       "2024-11-05"]
                                           :requested "1900-01-01"}}
                                   (. ((make-handler) {:jsonrpc "2.0"
                                                       :id 5
                                                       :method "tools/list"
                                                       :params {:_meta {"io.modelcontextprotocol/protocolVersion" "1900-01-01"
                                                                        "io.modelcontextprotocol/clientCapabilities" {}}}})
                                      :error))))
            (it "rejects requests without the required _meta before initialize"
                (fn []
                  (let [handle (make-handler)]
                    (assert.are.equal -32602
                                      (. (handle {:jsonrpc "2.0"
                                                  :id 6
                                                  :method "tools/list"})
                                         :error :code))
                    (assert.are.equal -32602
                                      (. (handle {:jsonrpc "2.0"
                                                  :id 7
                                                  :method "tools/list"
                                                  :params {:_meta {"io.modelcontextprotocol/protocolVersion" "2026-07-28"}}})
                                         :error :code)))))
            (it "serves legacy clients after initialize"
                (fn []
                  (let [handle (make-handler)]
                    (assert.are.same {:protocolVersion "2025-06-18"
                                      :capabilities {:tools {}}
                                      :serverInfo {:name "ezu"
                                                   :version "1.2.3"}
                                      :instructions "Use it."}
                                     (. (handle {:jsonrpc "2.0"
                                                 :id 1
                                                 :method "initialize"
                                                 :params {:protocolVersion "2025-06-18"
                                                          :capabilities {}}})
                                        :result))
                    (assert.is_nil (handle {:jsonrpc "2.0"
                                            :method "notifications/initialized"}))
                    (let [r (handle {:jsonrpc "2.0" :id 2 :method "tools/list"})]
                      (assert.is_nil r.result.resultType)
                      (assert.are.equal "t" (. r.result.tools 1 :name)))
                    (assert.are.same {}
                                     (. (handle {:jsonrpc "2.0"
                                                 :id 3
                                                 :method "ping"})
                                        :result)))))
            (it "offers its latest legacy version to an unknown one"
                (fn []
                  (assert.are.equal "2025-11-25"
                                    (. ((make-handler) {:jsonrpc "2.0"
                                                        :id 1
                                                        :method "initialize"
                                                        :params {:protocolVersion "2024-01-01"
                                                                 :capabilities {}}})
                                       :result :protocolVersion))))
            (it "ignores notifications and rejects malformed requests"
                (fn []
                  (let [handle (make-handler)]
                    (assert.is_nil (handle {:jsonrpc "2.0"
                                            :method "notifications/cancelled"
                                            :params {:requestId 1}}))
                    (assert.are.same {:jsonrpc "2.0"
                                      :id json.null
                                      :error {:code -32600
                                              :message "Invalid request"}}
                                     (handle [1 2]))
                    (assert.are.equal -32600
                                      (. (handle {:jsonrpc "2.0" :id 9}) :error
                                         :code)))))))

(describe "mcp.handler conformance"
          (fn []
            (it "gives caching hints on discovery and tool lists"
                (fn []
                  (let [handle (make-handler)]
                    (each [_ method (ipairs ["server/discover" "tools/list"])]
                      (let [r (. (handle {:jsonrpc "2.0"
                                          :id 1
                                          : method
                                          :params {:_meta modern}})
                                 :result)]
                        (assert.are.equal 0 r.ttlMs)
                        (assert.are.equal :private r.cacheScope))))))
            (it "takes only string and integer ids"
                (fn []
                  (let [handle (make-handler)]
                    (each [_ id (ipairs [json.null true 1.5 {:a 1}])]
                      (assert.are.equal -32600
                                        (. (handle {:jsonrpc "2.0"
                                                    : id
                                                    :method "ping"
                                                    :params {:_meta modern}})
                                           :error :code))))))
            (it "rejects params that aren't an object, and null capabilities"
                (fn []
                  (let [handle (make-handler)]
                    (assert.are.equal -32602
                                      (. (handle {:jsonrpc "2.0"
                                                  :id 1
                                                  :method "tools/list"
                                                  :params 5})
                                         :error :code))
                    (assert.are.equal -32602
                                      (. (handle {:jsonrpc "2.0"
                                                  :id 1
                                                  :method "tools/list"
                                                  :params {:_meta {"io.modelcontextprotocol/protocolVersion" "2026-07-28"
                                                                   "io.modelcontextprotocol/clientCapabilities" json.null}}})
                                         :error :code)))))
            (it "lists every version it speaks when one isn't"
                (fn []
                  (assert.are.same ["2026-07-28"
                                    "2025-11-25"
                                    "2025-06-18"
                                    "2025-03-26"
                                    "2024-11-05"]
                                   (. ((make-handler) {:jsonrpc "2.0"
                                                       :id 5
                                                       :method "tools/list"
                                                       :params {:_meta {"io.modelcontextprotocol/protocolVersion" "1900-01-01"
                                                                        "io.modelcontextprotocol/clientCapabilities" {}}}})
                                      :error :data :supported))))))

(describe "mcp.serve"
          (fn []
            (it "answers one line per message until input ends"
                (fn []
                  (let [lines ["{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}"
                               "not json"
                               ""
                               "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/x\"}"]
                        out []]
                    (var i 0)
                    (mcp.serve (fn [msg]
                                 (when msg.id
                                   {:jsonrpc "2.0"
                                    :id 1
                                    :result {:resultType :complete}}))
                               (fn []
                                 (set i (+ i 1))
                                 (. lines i))
                               #(table.insert out $))
                    (assert.are.equal 2 (length out))
                    (assert.are.equal "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{\"resultType\":\"complete\"}}"
                                      (. out 1))
                    (assert.are.equal "{\"error\":{\"code\":-32700,\"message\":\"Parse error\"},\"id\":null,\"jsonrpc\":\"2.0\"}"
                                      (. out 2)))))
            (it "answers JSON-RPC batches, which 2025-03-26 has"
                (fn []
                  (let [lines ["[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"a\"},{\"jsonrpc\":\"2.0\",\"method\":\"n\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"b\"}]"
                               "[{\"jsonrpc\":\"2.0\",\"method\":\"n\"}]"
                               "[]"]
                        out []]
                    (var i 0)
                    (mcp.serve (fn [msg]
                                 (when msg.id
                                   {:jsonrpc "2.0" :id msg.id :result {}}))
                               (fn []
                                 (set i (+ i 1))
                                 (. lines i))
                               #(table.insert out $))
                    (assert.are.same ["[{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{}},{\"id\":2,\"jsonrpc\":\"2.0\",\"result\":{}}]"
                                      "{\"error\":{\"code\":-32600,\"message\":\"Invalid request\"},\"id\":null,\"jsonrpc\":\"2.0\"}"]
                                     out))))
            (it "writes valid UTF-8 whatever the input"
                (fn []
                  (let [out []]
                    (var done false)
                    (mcp.serve (fn [_]
                                 {:jsonrpc "2.0"
                                  :id 1
                                  :result {:text "a\255b"}})
                               (fn []
                                 (when (not done)
                                   (set done true)
                                   "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\"}"))
                               #(table.insert out $))
                    (assert.is_truthy (utf8.len (. out 1)))
                    (assert.is_truthy (: (. out 1) :find "a\239\191\189b" 1
                                         true)))))))

(describe "mcp.workflow-tool"
          (fn []
            (it "describes a workflow with its inputs schema"
                (fn []
                  (assert.are.same {:name "workflow.fetchPet"
                                    :title "Fetch a pet"
                                    :description "Arazzo workflow fetchPet\n\nFetch a pet\n\nBy id."
                                    :inputSchema {:type :object
                                                  :properties {:id {:type :string}}}
                                    :annotations {:readOnlyHint false
                                                  :destructiveHint true
                                                  :idempotentHint false
                                                  :openWorldHint true}}
                                   (mcp.workflow-tool {:workflowId "fetchPet"
                                                       :summary "Fetch a pet"
                                                       :description "By id."}
                                                      {:type :object
                                                       :properties {:id {:type :string}}}))))
            (it "takes no inputs without a schema, and keeps names valid"
                (fn []
                  (let [t (mcp.workflow-tool {:workflowId "a b/c"} nil)]
                    (assert.are.equal "workflow.a_b_c" t.name)
                    (assert.are.same {:type :object
                                      :additionalProperties false}
                                     t.inputSchema))))
            (it "names a workflow with command words by them"
                (fn []
                  (let [t (mcp.workflow-tool {:workflowId "create"} nil
                                             ["compute" "instance" "create"])]
                    (assert.are.equal "workflow.compute_instance_create" t.name)
                    (assert.are.equal "Arazzo workflow create" t.description))))))

(fn write-docs [docs]
  "Write docs, {file-name doc}, as JSON in a new directory; returns it."
  (let [dir (os.tmpname)]
    (os.remove dir)
    (os.execute (.. "mkdir -p '" dir "'"))
    (each [name doc (pairs docs)]
      (with-open [f (io.open (.. dir "/" name) :w)]
        (f:write (json.encode doc))))
    dir))

(fn remove-docs [dir docs]
  (each [name (pairs docs)]
    (os.remove (.. dir "/" name)))
  (os.remove dir))

(fn flow [id ?command ?extra]
  (doto (collect [k v (pairs (or ?extra {}))]
          k
          v)
    (tset :workflowId id)
    (tset :x-ezu-command ?command)
    (tset :steps [])))

(local mounting-docs
       {"index.json" {:arazzo "1.1.0"
                      :info {:title "Cloud" :version "1"}
                      :sourceDescriptions [{:name "compute"
                                            :url "compute.json"
                                            :type "arazzo"
                                            :x-ezu-command "compute"}
                                           {:name "plain"
                                            :url "plain.json"
                                            :type "arazzo"
                                            :x-ezu-command "misc"}]
                      :workflows [(flow "zones" "zone list")
                                  (flow "index-helper")]}
        "compute.json" {:arazzo "1.1.0"
                        :info {:title "Compute" :version "1"}
                        :sourceDescriptions [{:name "sks"
                                              :url "sks.json"
                                              :type "arazzo"
                                              :x-ezu-command "sks"}]
                        :workflows [(flow "instance-create" "instance create"
                                          {:summary "Create an instance"
                                           :inputs {:type :object
                                                    :properties {:name {:type :string}}
                                                    :required [:name]}
                                           :outputs {:name "$inputs.name"}})
                                    (flow "instance-id")]}
        "sks.json" {:arazzo "1.1.0"
                    :info {:title "SKS" :version "1"}
                    ;; back to compute: offered once, where first reached
                    :sourceDescriptions [{:name "compute"
                                          :url "compute.json"
                                          :type "arazzo"
                                          :x-ezu-command "compute"}]
                    :workflows [(flow "cluster-list" "cluster list")]}
        "plain.json" {:arazzo "1.1.0"
                      :info {:title "Plain" :version "1"}
                      :workflows [(flow "a-flow")]}})

(describe "mcp.command-workflows"
          (fn []
            (it "offers the workflows command words reach, mounted ones included, by their words"
                (fn []
                  (let [arazzo (require :ezu.arazzo)
                        dir (write-docs mounting-docs)
                        doc (arazzo.load-doc (.. dir "/index.json"))
                        found (mcp.command-workflows doc
                                                     (arazzo.source-loader {}))]
                    (remove-docs dir mounting-docs)
                    (assert.are.same [["compute" "instance" "create"]
                                      ["compute" "sks" "cluster" "list"]
                                      ["misc" "a-flow"]
                                      ["zone" "list"]]
                                     (icollect [_ e (ipairs found)] e.words))
                    (assert.are.same ["instance-create"
                                      "cluster-list"
                                      "a-flow"
                                      "zones"]
                                     (icollect [_ e (ipairs found)]
                                       e.workflow.workflowId))
                    (assert.are.equal (.. dir "/compute.json")
                                      (arazzo.location (. found 1 :doc)))
                    (assert.are.equal (.. dir "/sks.json")
                                      (arazzo.location (. found 2 :doc)))
                    (assert.are.equal doc (. found 4 :doc)))))
            (it "offers every workflow of a document without command words, without words"
                (fn []
                  (let [doc {:workflows [(flow "b") (flow "a")]}]
                    (assert.are.same [{:workflow (. doc.workflows 1) : doc}
                                      {:workflow (. doc.workflows 2) : doc}]
                                     (mcp.command-workflows doc
                                                            #(error "no sources"))))))
            (it "loads only the sources next to the document, unless trusted"
                (fn []
                  (let [arazzo (require :ezu.arazzo)
                        elsewhere (write-docs {"plain.json" (. mounting-docs
                                                               "plain.json")})
                        docs {"index.json" {:arazzo "1.1.0"
                                            :info {:title "Far" :version "1"}
                                            :sourceDescriptions [{:name "far"
                                                                  :url (.. elsewhere
                                                                           "/plain.json")
                                                                  :type "arazzo"
                                                                  :x-ezu-command "far"}]
                                            :workflows []}}
                        dir (write-docs docs)
                        doc (arazzo.load-doc (.. dir "/index.json"))
                        (ok err) (pcall mcp.command-workflows doc
                                        (arazzo.source-loader {}))
                        trusted (mcp.command-workflows doc
                                                       (arazzo.source-loader {:trust-sources true}))]
                    (remove-docs dir docs)
                    (remove-docs elsewhere {"plain.json" true})
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "not next to the document" 1 true))
                    (assert.are.same [["far" "a-flow"]]
                                     (icollect [_ e (ipairs trusted)] e.words)))))
            (it "serves the tools of mounted workflows, run in their own document"
                (fn []
                  (let [arazzo (require :ezu.arazzo)
                        dir (write-docs mounting-docs)
                        doc (arazzo.load-doc (.. dir "/index.json"))
                        found (mcp.command-workflows doc
                                                     (arazzo.source-loader {}))
                        calls (collect [_ e (ipairs found)]
                                (values (. (mcp.workflow-tool e.workflow nil
                                                              e.words)
                                           :name)
                                        #(arazzo.run-workflow e.doc
                                                              e.workflow.workflowId
                                                              $ {})))
                        handle (mcp.handler {:tools (icollect [_ e (ipairs found)]
                                                      (mcp.workflow-tool e.workflow
                                                                         (arazzo.workflow-inputs e.doc
                                                                                                 e.workflow)
                                                                         e.words))
                                             :call (fn [name arguments]
                                                     {:content [{:type :text
                                                                 :text (json.encode (. ((. calls
                                                                                           name) arguments)
                                                                                       :outputs))}]
                                                      :isError false})
                                             :version "1"})
                        listed (handle {:jsonrpc "2.0"
                                        :id 1
                                        :method "tools/list"
                                        :params {:_meta modern}})
                        called (handle {:jsonrpc "2.0"
                                        :id 2
                                        :method "tools/call"
                                        :params {:_meta modern
                                                 :name "workflow.compute_instance_create"
                                                 :arguments {:name "web1"}}})]
                    (remove-docs dir mounting-docs)
                    (assert.are.same ["workflow.compute_instance_create"
                                      "workflow.compute_sks_cluster_list"
                                      "workflow.misc_a-flow"
                                      "workflow.zone_list"]
                                     (icollect [_ t (ipairs listed.result.tools)]
                                       t.name))
                    (assert.are.same {:type :object
                                      :properties {:name {:type :string}}
                                      :required [:name]}
                                     (. listed.result.tools 1 :inputSchema))
                    (assert.are.equal "{\"name\":\"web1\"}"
                                      (. called.result.content 1 :text)))))))

(describe "mcp fixes from review"
          (fn []
            (it "leaves read-only properties of allOf members out of required"
                (fn []
                  (assert.are.same ["name"]
                                   (. (mcp.json-schema {:required ["id" "name"]
                                                        :allOf [{:properties {:id {:readOnly true}
                                                                              :name {}}}]}
                                                       false nil true)
                                      :required))))
            (it "drops nullable when only annotations are left"
                (fn []
                  (assert.are.same {:description "d"}
                                   (mcp.json-schema {:description "d"
                                                     :nullable true}
                                                    true))))
            (it "sends JSON Lines and other text bodies as given"
                (fn []
                  (let [c (ezu.client {:openapi "3.1.0"
                                       :info {}
                                       :servers [{:url "https://h"}]
                                       :paths {"/x" {:post {:operationId "postX"
                                                            :requestBody {:content {:application/x-ndjson {}}}}}}}
                                      {:http-fn #nil})]
                    (assert.are.equal "{\"a\":1}\n{\"a\":2}"
                                      (. (mcp.request c.post-x
                                                      {:body "{\"a\":1}\n{\"a\":2}"})
                                         :body)))))
            (it "takes null arguments as none"
                (fn []
                  (let [(handle calls) (make-handler)]
                    (handle {:jsonrpc "2.0"
                             :id 1
                             :method "tools/call"
                             :params {:_meta modern
                                      :name "t"
                                      :arguments json.null}})
                    (assert.are.same [["t" {}]] calls))))
            (it "answers an empty object as an invalid request"
                (fn []
                  (assert.are.equal -32600 (. ((make-handler) {}) :error :code))
                  (assert.is_nil ((make-handler) {:jsonrpc "2.0"
                                                  :id 1
                                                  :result {}}))))
            (it "cleans invalid UTF-8 in linear time"
                (fn []
                  (let [text (string.rep "a\255" 100000)
                        out []
                        t0 (os.clock)]
                    (var done false)
                    (mcp.serve (fn [_] {:jsonrpc "2.0" :id 1 :result {: text}})
                               (fn []
                                 (when (not done)
                                   (set done true)
                                   "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\"}"))
                               #(table.insert out $))
                    (assert.is_true (< (- (os.clock) t0) 1))
                    (assert.is_truthy (utf8.len (. out 1))))))))
