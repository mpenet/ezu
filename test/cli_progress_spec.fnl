;; ABOUTME: Specs for the live progress of Arazzo workflows: step lines, polling,
;; ABOUTME: failures and nesting, on a terminal (rewritten in place) and in logs.
(local progress (require :ezu.cli.progress))

(fn screen []
  "A terminal: \r\27[K clears the current line, \n ends it. :lines gives the
lines ended so far, then the current one if it isn't empty."
  (let [done []
        state {:current ""}]
    {:write (fn [s]
              (var rest s)
              (while (> (length rest) 0)
                (if (= (rest:sub 1 4) "\r\27[K")
                    (do
                      (set state.current "")
                      (set rest (rest:sub 5)))
                    (= (rest:sub 1 1) "\n")
                    (do
                      (table.insert done state.current)
                      (set state.current "")
                      (set rest (rest:sub 2)))
                    (let [text (rest:match "^[^\r\n]+")]
                      (set state.current (.. state.current text))
                      (set rest (rest:sub (+ 1 (length text))))))))
     :lines (fn []
              (doto (icollect [_ l (ipairs done)] l)
                (table.insert (when (not= state.current "") state.current))))}))

(fn clock [times]
  "A clock returning times one after the other."
  (var i 0)
  (fn []
    (set i (+ i 1))
    (. times i)))

(fn run [events opts]
  "The lines a reporter shows for events, then a finish."
  (let [term (screen)
        reporter (progress.reporter {:write term.write
                                     :tty opts.tty
                                     :clock (clock (or opts.times
                                                       [0 0 0 0 0 0 0 0]))})]
    (each [_ e (ipairs events)]
      (reporter.on-step e))
    (when opts.finish
      (reporter.finish (table.unpack opts.finish)))
    (term.lines)))

(fn ev [status fields]
  (doto fields
    (tset :status status)
    (tset :workflow (or fields.workflow "wf"))
    (tset :depth (or fields.depth 0))))

(local two-steps [(ev :workflow
                      {:steps [{:step "template" :op-ref "list-templates"}
                               {:step "instance-type"
                                :op-ref "list-instance-types"}]})
                  (ev :running
                      {:step "template"
                       :index 1
                       :count 2
                       :attempt 1
                       :op-ref "list-templates"})
                  (ev :done
                      {:step "template"
                       :index 1
                       :count 2
                       :attempt 1
                       :op-ref "list-templates"
                       :passed true
                       :elapsed 0.205
                       :response {:status 200}})
                  (ev :running
                      {:step "instance-type"
                       :index 2
                       :count 2
                       :attempt 1
                       :op-ref "list-instance-types"})
                  (ev :done
                      {:step "instance-type"
                       :index 2
                       :count 2
                       :attempt 1
                       :op-ref "list-instance-types"
                       :passed true
                       :elapsed 1.5
                       :response {:status 200}})])

(local polling [(ev :workflow {:steps [{:step "wait" :op-ref "get-operation"}]})
                (ev :running
                    {:step "wait"
                     :index 1
                     :count 1
                     :attempt 1
                     :op-ref "get-operation"})
                (ev :done {:step "wait"
                           :index 1
                           :count 1
                           :attempt 1
                           :op-ref "get-operation"
                           :passed false
                           :failure "$response.body#/state == 'success' ($response.body#/state is \"pending\")"
                           :elapsed 0.18
                           :response {:status 200}})
                (ev :action {:step "wait"
                             :index 1
                             :count 1
                             :attempt 1
                             :action {:type "goto" :stepId "wait"}
                             :wait 3})
                (ev :running
                    {:step "wait"
                     :index 1
                     :count 1
                     :attempt 2
                     :op-ref "get-operation"})
                (ev :done {:step "wait"
                           :index 1
                           :count 1
                           :attempt 2
                           :op-ref "get-operation"
                           :passed true
                           :elapsed 0.2
                           :response {:status 200}})])

(describe "workflow progress in a log"
          (fn []
            (it "prints a line per step, aligned, and the workflow's"
                (fn []
                  (assert.are.same ["✓ 1/2 template       list-templates       205ms  200"
                                    "✓ 2/2 instance-type  list-instance-types  1.50s  200"
                                    "✓ workflow wf  2.00s"]
                                   (run two-steps {:finish [true "wf" 2]}))))
            (it "prints each poll with why the step goes on, then the attempts"
                (fn []
                  (assert.are.same ["↻ 1/1 wait  get-operation  180ms  200  again in 3s · $response.body#/state == 'success' ($response.body#/state is \"pending\")"
                                    "✓ 1/1 wait  get-operation  2 attempts · 3.40s  200"
                                    "✓ workflow wf  3.50s"]
                                   (run polling
                                        {:times [0 0.18 0.2 3.2 3.4]
                                         :finish [true "wf" 3.5]}))))
            (it "marks the step that failed the workflow"
                (fn []
                  (assert.are.same ["✗ 1/1 template  list-templates  205ms  403"
                                    "✗ workflow wf failed  300ms"]
                                   (run [(ev :workflow
                                             {:steps [{:step "template"
                                                       :op-ref "list-templates"}]})
                                         (ev :running
                                             {:step "template"
                                              :index 1
                                              :count 1
                                              :attempt 1
                                              :op-ref "list-templates"})
                                         (ev :done
                                             {:step "template"
                                              :index 1
                                              :count 1
                                              :attempt 1
                                              :op-ref "list-templates"
                                              :passed false
                                              :failure "$statusCode == 200 ($statusCode is 403)"
                                              :elapsed 0.205
                                              :response {:status 403}})]
                                        {:finish [false "wf" 0.3]}))))
            (it "says error for a request that failed in transport"
                (fn []
                  (assert.are.same ["✗ 1/1 s1  op  1.00s  error"
                                    "✗ workflow wf failed  1.00s"]
                                   (run [(ev :workflow
                                             {:steps [{:step "s1" :op-ref "op"}]})
                                         (ev :done
                                             {:step "s1"
                                              :index 1
                                              :count 1
                                              :attempt 1
                                              :op-ref "op"
                                              :passed false
                                              :error "request failed: connection refused"
                                              :elapsed 1})]
                                        {:finish [false "wf" 1]}))))
            (it "shows where actions go"
                (fn []
                  (assert.are.same ["✗ 1/1 s1  op  10ms  500  goto cleanup · $statusCode == 200 ($statusCode is 500)"
                                    "✓ workflow wf  20ms"]
                                   (run [(ev :workflow
                                             {:steps [{:step "s1" :op-ref "op"}]})
                                         (ev :done
                                             {:step "s1"
                                              :index 1
                                              :count 1
                                              :attempt 1
                                              :op-ref "op"
                                              :passed false
                                              :failure "$statusCode == 200 ($statusCode is 500)"
                                              :elapsed 0.01
                                              :response {:status 500}})
                                         (ev :action
                                             {:step "s1"
                                              :index 1
                                              :count 1
                                              :attempt 1
                                              :action {:type "goto"
                                                       :stepId "cleanup"}
                                              :wait 0})]
                                        {:finish [true "wf" 0.02]}))))
            (it "shows the action after a step that passed"
                (fn []
                  (assert.are.same ["✓ 1/1 s1  op  10ms  200  end"
                                    "✓ workflow wf  20ms"]
                                   (run [(ev :workflow
                                             {:steps [{:step "s1" :op-ref "op"}]})
                                         (ev :done
                                             {:step "s1"
                                              :index 1
                                              :count 1
                                              :attempt 1
                                              :op-ref "op"
                                              :passed true
                                              :elapsed 0.01
                                              :response {:status 200}})
                                         (ev :action
                                             {:step "s1"
                                              :index 1
                                              :count 1
                                              :attempt 1
                                              :action {:type "end"}
                                              :wait 0})]
                                        {:finish [true "wf" 0.02]}))))
            (it "indents the steps of a sub-workflow"
                (fn []
                  (assert.are.same ["  ✓ 1/1 s1  op  100ms  200"
                                    "✓ 1/1 call  workflow inner  150ms"
                                    "✓ workflow outer  200ms"]
                                   (run [(ev :workflow
                                             {:workflow "outer"
                                              :steps [{:step "call"
                                                       :op-ref "inner"
                                                       :calls "workflow"}]})
                                         (ev :running
                                             {:workflow "outer"
                                              :step "call"
                                              :index 1
                                              :count 1
                                              :attempt 1
                                              :op-ref "inner"
                                              :calls "workflow"})
                                         (ev :workflow
                                             {:workflow "inner"
                                              :depth 1
                                              :steps [{:step "s1" :op-ref "op"}]})
                                         (ev :done
                                             {:workflow "inner"
                                              :depth 1
                                              :step "s1"
                                              :index 1
                                              :count 1
                                              :attempt 1
                                              :op-ref "op"
                                              :passed true
                                              :elapsed 0.1
                                              :response {:status 200}})
                                         (ev :done
                                             {:workflow "outer"
                                              :step "call"
                                              :index 1
                                              :count 1
                                              :attempt 1
                                              :op-ref "inner"
                                              :calls "workflow"
                                              :passed true
                                              :elapsed 0.15})]
                                        {:finish [true "outer" 0.2]}))))
            (it "names another document's workflow by its source"
                (fn []
                  (assert.are.same ["✓ 1/1 call  workflow common.inner  150ms"
                                    "✓ workflow outer  200ms"]
                                   (run [(ev :workflow
                                             {:workflow "outer"
                                              :steps [{:step "call"
                                                       :op-ref "$sourceDescriptions.common.inner"
                                                       :calls "workflow"}]})
                                         (ev :done
                                             {:workflow "outer"
                                              :step "call"
                                              :index 1
                                              :count 1
                                              :attempt 1
                                              :op-ref "$sourceDescriptions.common.inner"
                                              :calls "workflow"
                                              :passed true
                                              :elapsed 0.15})]
                                        {:finish [true "outer" 0.2]}))))
            (it "names operations briefly"
                (fn []
                  (assert.are.same ["✓ 1/2 a  getPet          1ms  200"
                                    "✓ 2/2 b  GET /pets/{id}  1ms  200"
                                    "✓ workflow wf  2ms"]
                                   (run [(ev :workflow
                                             {:steps [{:step "a"
                                                       :op-ref "$sourceDescriptions.api.getPet"}
                                                      {:step "b"
                                                       :op-ref "{$sourceDescriptions.api.url}#/paths/~1pets~1{id}/get"}]})
                                         (ev :done
                                             {:step "a"
                                              :index 1
                                              :count 2
                                              :attempt 1
                                              :op-ref "$sourceDescriptions.api.getPet"
                                              :passed true
                                              :elapsed 0.001
                                              :response {:status 200}})
                                         (ev :done
                                             {:step "b"
                                              :index 2
                                              :count 2
                                              :attempt 1
                                              :op-ref "{$sourceDescriptions.api.url}#/paths/~1pets~1{id}/get"
                                              :passed true
                                              :elapsed 0.001
                                              :response {:status 200}})]
                                        {:finish [true "wf" 0.002]}))))
            (it "escapes control characters of step ids"
                (fn []
                  (assert.are.same ["✓ 1/1 s\\x1B]0;P\\x07  op  1ms  200"
                                    "✓ workflow wf  1ms"]
                                   (run [(ev :workflow
                                             {:steps [{:step "s\027]0;P\007"
                                                       :op-ref "op"}]})
                                         (ev :done
                                             {:step "s\027]0;P\007"
                                              :index 1
                                              :count 1
                                              :attempt 1
                                              :op-ref "op"
                                              :passed true
                                              :elapsed 0.001
                                              :response {:status 200}})]
                                        {:finish [true "wf" 0.001]}))))))

(describe "workflow progress on a terminal"
          (fn []
            (it "shows the running step, then replaces it with its result"
                (fn []
                  (let [term (screen)
                        reporter (progress.reporter {:write term.write
                                                     :tty true
                                                     :clock #0})]
                    (reporter.on-step (. two-steps 1))
                    (reporter.on-step (. two-steps 2))
                    (assert.are.same ["→ 1/2 template       list-templates       …"]
                                     (term.lines))
                    (for [i 3 5]
                      (reporter.on-step (. two-steps i)))
                    (reporter.finish true "wf" 2)
                    (assert.are.same ["✓ 1/2 template       list-templates       205ms  200"
                                      "✓ 2/2 instance-type  list-instance-types  1.50s  200"
                                      "✓ workflow wf  2.00s"]
                                     (term.lines)))))
            (it "keeps a polled step on one line"
                (fn []
                  (let [term (screen)
                        reporter (progress.reporter {:write term.write
                                                     :tty true
                                                     :clock (clock [0
                                                                    0.18
                                                                    0.2
                                                                    3.2
                                                                    3.4])})]
                    (for [i 1 4]
                      (reporter.on-step (. polling i)))
                    (assert.are.same ["↻ 1/1 wait  get-operation  180ms  200  again in 3s · $response.body#/state == 'success' ($response.body#/state is \"pending\")"]
                                     (term.lines))
                    (reporter.on-step (. polling 5))
                    (assert.are.same ["↻ 1/1 wait  get-operation  attempt 2 · 3.20s …"]
                                     (term.lines))
                    (reporter.on-step (. polling 6))
                    (reporter.finish true "wf" 3.5)
                    (assert.are.same ["✓ 1/1 wait  get-operation  2 attempts · 3.40s  200"
                                      "✓ workflow wf  3.50s"]
                                     (term.lines)))))
            (it "fits the lines it rewrites to the terminal's width"
                (fn []
                  (let [term (screen)
                        reporter (progress.reporter {:write term.write
                                                     :tty true
                                                     :color true
                                                     :columns 40
                                                     :clock (clock [0 0.18 0.2])})]
                    (for [i 1 4]
                      (reporter.on-step (. polling i)))
                    (let [[line] (term.lines)
                          visible (line:gsub "\027%[[%d;]*m" "")]
                      (assert.are.equal 39 (utf8.len visible))
                      (assert.is_truthy (visible:find "…$"))
                      ;; colors are closed
                      (assert.is_truthy (line:find "\027%[0m$"))))))
            (it "keeps a line rewritten in place on one line"
                (fn []
                  (let [term (screen)
                        reporter (progress.reporter {:write term.write
                                                     :tty true
                                                     :clock #0})]
                    (reporter.on-step (. polling 1))
                    (reporter.on-step (. polling 2))
                    (reporter.on-step (doto (collect [k v (pairs (. polling 3))]
                                              k
                                              v)
                                        (tset :failure
                                              "$statusCode == 201\n\tand more")))
                    (reporter.on-step (. polling 4))
                    (let [[line & more] (term.lines)]
                      (assert.are.same [] more)
                      (assert.is_truthy (line:find "$statusCode == 201  and more"
                                                   1 true))))))
            (it "ends the line it is rewriting before a warning"
                (fn []
                  (let [term (screen)
                        reporter (progress.reporter {:write term.write
                                                     :tty true
                                                     :clock #0})]
                    (reporter.on-step (. two-steps 1))
                    (reporter.on-step (. two-steps 2))
                    (reporter.warn "condition 'x' can't be evaluated")
                    (assert.are.same ["→ 1/2 template       list-templates"
                                      "warning: condition 'x' can't be evaluated"]
                                     (term.lines)))))
            (it "keeps the line of a step whose sub-workflow prints its own"
                (fn []
                  (let [term (screen)
                        reporter (progress.reporter {:write term.write
                                                     :tty true
                                                     :clock #0})]
                    (each [_ e (ipairs [(ev :workflow
                                            {:workflow "outer"
                                             :steps [{:step "call"
                                                      :op-ref "inner"
                                                      :calls "workflow"}]})
                                        (ev :running
                                            {:workflow "outer"
                                             :step "call"
                                             :index 1
                                             :count 1
                                             :attempt 1
                                             :op-ref "inner"
                                             :calls "workflow"})
                                        (ev :workflow
                                            {:workflow "inner"
                                             :depth 1
                                             :steps [{:step "s1" :op-ref "op"}]})
                                        (ev :running
                                            {:workflow "inner"
                                             :depth 1
                                             :step "s1"
                                             :index 1
                                             :count 1
                                             :attempt 1
                                             :op-ref "op"})])]
                      (reporter.on-step e))
                    (assert.are.same ["→ 1/1 call  workflow inner"
                                      "  → 1/1 s1  op  …"]
                                     (term.lines)))))
            (it "colors marks and statuses"
                (fn []
                  (let [term (screen)
                        reporter (progress.reporter {:write term.write
                                                     :tty false
                                                     :color true
                                                     :clock #0})]
                    (reporter.on-step (. two-steps 1))
                    (reporter.on-step (. two-steps 3))
                    (reporter.finish true "wf" 1)
                    (let [[line] (term.lines)]
                      (assert.is_truthy (line:find "\027[32m✓\027[0m" 1 true))
                      (assert.is_truthy (line:find "\027[32m200\027[0m" 1 true))))))))
