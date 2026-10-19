;; ABOUTME: Help text for the ezu command line: operation help with ezu op
;; ABOUTME: usage lines, and Arazzo workflow help for ezu az --help.
(local util (require :ezu.util))
(local doc (require :ezu.doc))

(local cli-style
       {:usage (fn [name op-spec path-params query-params]
                 (let [parts [name]]
                   (each [_ p (ipairs path-params)]
                     (table.insert parts (.. "<" p.name ">")))
                   (when op-spec.requestBody
                     (table.insert parts "[-d JSON|@file|@-]"))
                   (when (> (length query-params) 0)
                     (table.insert parts "[--q.KEY=VAL ...]"))
                   (.. "ezu op <profile-or-schema> " (table.concat parts " "))))
        :query-heading "Query params (--q.KEY=VAL):"
        :body-hint "  Use -d JSON, --body=@file, --body=@- for stdin, or --b.KEY=VAL for individual fields"})

(fn build-cli [path method op-spec ?name]
  (doc.render path method op-spec cli-style ?name))

(fn step-target [step]
  "What a workflow step calls, for display."
  (if step.operationId (tostring step.operationId)
      step.workflowId (.. "workflow " step.workflowId)
      step.operationPath (let [ptr (or (step.operationPath:match "#/paths/(.+)$")
                                       "")
                               (path method) (ptr:match "^(.+)/([^/]+)$")]
                           (if path
                               (.. (method:upper) " "
                                   (util.unescape-pointer path))
                               step.operationPath))
      "?"))

(fn build-workflow [wf inputs-schema positional ?command]
  "Help text for an Arazzo workflow. inputs-schema is the workflow's resolved
inputs JSON Schema; positional lists inputs that may be passed positionally;
?command is the command line running it (ezu az NAME WORKFLOW by default)."
  (let [lines []
        add #(table.insert lines $)
        required (collect [_ r (ipairs (util.required-names inputs-schema))]
                   r
                   true)
        props (or (?. inputs-schema :properties) {})
        names (icollect [name (pairs props)] name)]
    (table.sort names (fn [a b]
                        (if (= (. required a) (. required b)) (< a b)
                            (= true (. required a)))))
    (add wf.workflowId)
    (when (and wf.summary (not= wf.summary "")) (add (.. "\n" wf.summary)))
    (when (and wf.description (not= wf.description "")
               (not= wf.description wf.summary))
      (add wf.description))
    (add (.. "\nUsage: "
             (or ?command (.. "ezu az <name-or-file> " wf.workflowId))
             (table.concat (icollect [_ n (ipairs positional)] (.. " <" n ">")))
             " [name=value ...]"))
    (let [question (. wf :x-ezu-confirm)]
      (when (= (type question) :string)
        (add (.. "\nAsks first: " question " (--yes answers yes)"))))
    (if (= 0 (length names))
        (add "\nInputs: none")
        (do
          (add "\nInputs:")
          (each [_ name (ipairs names)]
            (let [prop (. props name)]
              (add (string.format "  %-16s %s%s" name (doc.type-name prop)
                                  (doc.param-extras {:schema prop
                                                     :description (when (= (type prop)
                                                                           :table)
                                                                    prop.description)}
                                                    (. required name))))))))
    (let [steps (or wf.steps [])
          width (accumulate [w 0 _ s (ipairs steps)]
                  (math.max w (length (tostring s.stepId))))]
      (when (> (length steps) 0)
        (add "\nSteps:")
        (each [i step (ipairs steps)]
          (add (string.format (.. "  %d. %-" (+ width 2) "s %s") i
                              (tostring step.stepId) (step-target step))))))
    (table.concat lines "\n")))

{: build-cli : build-workflow}
