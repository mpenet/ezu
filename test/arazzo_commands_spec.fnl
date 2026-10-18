;; ABOUTME: Specs for the command words of Arazzo documents: x-ezu-command on
;; ABOUTME: workflows and sources, resolving the words of a command line.
(local commands (require :ezu.arazzo.commands))

(fn wf [id ?command ?summary]
  {:workflowId id :x-ezu-command ?command :summary ?summary :steps []})

(local compute
       {:arazzo "1.1.0"
        :info {:title "Compute" :summary "Instances and their kin"}
        :workflows [(wf "instance-list" "instance list" "List instances")
                    (wf "instance-create" "instance create"
                        "Create an instance")
                    (wf "instance-snapshot-list" "instance snapshot list")
                    (wf "instance-id" nil "Id of an instance")]})

(local index {:arazzo "1.1.0"
              :info {:title "Exoscale"}
              :sourceDescriptions [{:name "compute"
                                    :url "compute.yaml"
                                    :type "arazzo"
                                    :x-ezu-command "compute"}
                                   {:name "common"
                                    :url "common.yaml"
                                    :type "arazzo"}]
              :workflows [(wf "zones" "zone list" "List zones")]})

(local plain
       {:arazzo "1.1.0"
        :info {}
        :workflows [(wf "b-flow" nil "B") (wf "a-flow" nil "A")]})

(fn loader []
  "A loader of index's sources, recording what it loads."
  (let [loaded []]
    (values (fn [doc source]
              (table.insert loaded source.name)
              (assert (= doc index))
              (match source.name
                :compute compute
                _ (error (.. "no " source.name)))) loaded)))

(describe "resolving command words"
          (fn []
            (it "finds a workflow by its words, the rest being its arguments"
                (fn []
                  (let [r (commands.resolve compute
                                            ["instance"
                                             "create"
                                             "web1"
                                             "size=large"]
                                            #(error "no sources"))]
                    (assert.are.equal :workflow r.kind)
                    (assert.are.equal "instance-create" r.workflow.workflowId)
                    (assert.are.equal compute r.doc)
                    (assert.are.same ["web1" "size=large"] r.rest)
                    (assert.are.same ["instance" "create"] r.path))))
            (it "goes into a mounted document, loading only that one"
                (fn []
                  (let [(load loaded) (loader)
                        r (commands.resolve index ["compute" "instance" "list"]
                                            load)]
                    (assert.are.equal "instance-list" r.workflow.workflowId)
                    (assert.are.equal compute r.doc)
                    (assert.are.same [:compute] loaded))
                  (let [(load loaded) (loader)
                        r (commands.resolve index ["zone" "list"] load)]
                    (assert.are.equal "zones" r.workflow.workflowId)
                    (assert.are.same [] loaded))))
            (it "stops at a group when the words end"
                (fn []
                  (let [r (commands.resolve compute ["instance"] #nil)]
                    (assert.are.equal :group r.kind)
                    (assert.are.same ["instance"] r.path))))
            (it "runs a workflow by its id, as a document without commands does"
                (fn []
                  (let [r (commands.resolve compute ["instance-id" "web1"] #nil)
                        p (commands.resolve plain ["a-flow" "x=1"] #nil)]
                    (assert.are.equal "instance-id" r.workflow.workflowId)
                    (assert.are.same ["web1"] r.rest)
                    (assert.are.equal "a-flow" p.workflow.workflowId)
                    (assert.are.same ["x=1"] p.rest))))
            (it "says which word is unknown, with a suggestion"
                (fn []
                  (let [r (commands.resolve compute ["instanse" "list"] #nil)
                        deeper (commands.resolve compute ["instance" "lst"]
                                                 #nil)]
                    (assert.are.equal :unknown r.kind)
                    (assert.are.equal "instanse" r.word)
                    (assert.are.equal "instance" r.suggestion)
                    (assert.are.same [] r.path)
                    (assert.are.equal "lst" deeper.word)
                    (assert.are.equal "list" deeper.suggestion)
                    (assert.are.same ["instance"] deeper.path))))))

(describe "words and values"
          (fn []
            (it "suggests workflow ids at a document's top too"
                (fn []
                  (let [r (commands.resolve compute ["instance-di" "x"] #nil)]
                    (assert.are.equal "instance-id" r.suggestion))))
            (it "stops at the words given before --"
                (fn []
                  (let [doc {:workflows [(wf "inst" "inst")
                                         (wf "inst-list" "inst list")]}
                        r (commands.resolve doc ["inst" "list"] #nil 2)]
                    (assert.are.equal "inst" r.workflow.workflowId)
                    (assert.are.same ["list"] r.rest))))))

(describe "listing commands"
          (fn []
            (it "lists a group's words, groups with the words under them"
                (fn []
                  (let [(load) (loader)]
                    (assert.are.same [{:word "compute"
                                       :summary "Instances and their kin"}
                                      {:word "zone" :summary "list"}]
                                     (commands.entries (. (commands.resolve index
                                                                            []
                                                                            load)
                                                          :node)
                                                       load))
                    (assert.are.same [{:word "create"
                                       :summary "Create an instance"}
                                      {:word "list" :summary "List instances"}
                                      {:word "snapshot" :summary "list"}]
                                     (commands.entries (. (commands.resolve compute
                                                                            ["instance"]
                                                                            load)
                                                          :node)
                                                       load)))))
            (it "names workflows without an id so"
                (fn []
                  (assert.are.same [{:word "(no workflowId)" :summary "lost"}]
                                   (commands.entries (. (commands.resolve {:workflows [{:summary "lost"}]}
                                                                          []
                                                                          #nil)
                                                        :node)
                                                     #nil))))
            (it "lists a document without commands by workflow id"
                (fn []
                  (assert.are.same [{:word "b-flow" :summary "B"}
                                    {:word "a-flow" :summary "A"}]
                                   (commands.entries (. (commands.resolve plain
                                                                          []
                                                                          #nil)
                                                        :node)
                                                     #nil))))
            (it "tells whether a document has commands"
                (fn []
                  (assert.is_true (commands.commands? compute))
                  (assert.is_true (commands.commands? index))
                  (assert.is_false (commands.commands? plain))))))

(describe "problems with command words"
          (fn []
            (it "finds repeated commands, commands that are also groups, and bad words"
                (fn []
                  (assert.are.same ["b: x-ezu-command 'one two' is also workflow a's"
                                    "c: x-ezu-command 'one' is also a group of commands (one two)"
                                    "d: x-ezu-command must be words, like \"instance create\""
                                    "source api: x-ezu-command mounts an Arazzo document, and api isn't one"]
                                   (icollect [_ p (ipairs (commands.problems {:sourceDescriptions [{:name "api"
                                                                                                    :url "a.json"
                                                                                                    :type "openapi"
                                                                                                    :x-ezu-command "api"}]
                                                                              :workflows [(wf "a"
                                                                                              "one two")
                                                                                          (wf "b"
                                                                                              "one two")
                                                                                          (wf "c"
                                                                                              "one")
                                                                                          (wf "d"
                                                                                              "  ")]}))]
                                     (.. p.where ": " p.message)))))))
