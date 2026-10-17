;; ABOUTME: Checks an Arazzo document without running it: what steps call, their
;; ABOUTME: parameters and bodies, references, conditions and actions.
(local arazzo (require :ezu.arazzo))
(local expr (require :ezu.arazzo.expr))
(local iregexp (require :ezu.iregexp))
(local jsonpath (require :ezu.jsonpath))
(local json (require :ezu.json))

(local locations {:path true
                  :query true
                  :header true
                  :cookie true
                  :querystring true})

;; header parameters OpenAPI says to ignore: HTTP itself sets them
(local ignored-headers {:accept true :content-type true :authorization true})

;; an empty run: expressions resolve to nothing, but unknown ones still raise
(local empty-ctx {:inputs {} :steps {} :workflows {} :outputs {}})

(fn keys-of [t]
  (collect [k (pairs (if (= (type t) :table) t {}))]
    k
    true))

(fn list? [v]
  "Whether v is a list (a table with nothing but 1..n)."
  (and (= (type v) :table) (not= v json.null)
       (accumulate [ok true k (pairs v) &until (not ok)]
         (and (= (type k) :number) (<= 1 k (length v))))))

(fn list-of-tables? [v]
  (and (list? v)
       (accumulate [ok true _ item (ipairs v) &until (not ok)]
         (and (= (type item) :table) (not= item json.null)))))

(fn external? [workflow-id]
  "Whether workflow-id names a workflow of another Arazzo document."
  (and (= (type workflow-id) :string) (not= nil (workflow-id:match "^%$"))))

(fn param-key [location name]
  "location:name, header names lowercased: they match whatever their case."
  (.. location ":" (if (= location :header) (name:lower) name)))

(fn component [doc reference]
  "The component $components.KIND.NAME names, or nil."
  (let [(kind name) (reference:match "^%$components%.([^%.]+)%.(.+)$")]
    (?. doc :components kind name)))

(fn expressions-in [s]
  "The runtime expressions in string s: all of it, or the ones in {}."
  (if (s:match "^%$%a") [s] (icollect [e (s:gmatch "{(%$[^}]+)}")]
                              e)))

(fn checker [doc clients supplied]
  "The problems found in doc: [{:level :where :message}]."
  (let [problems []
        workflows (collect [_ wf (ipairs (if (list? doc.workflows)
                                             doc.workflows
                                             []))]
                    (when (and (= (type wf) :table)
                               (= (type wf.workflowId) :string))
                      (values wf.workflowId wf)))
        sources (collect [_ src (ipairs (if (list? doc.sourceDescriptions)
                                            doc.sourceDescriptions
                                            []))]
                  (when (and (= (type src) :table) src.name)
                    (values src.name true)))]
    (fn report [level where message]
      (table.insert problems {: level : where : message}))

    (fn check-workflow-id [where id]
      "Report a workflowId that is not one of the document's workflows."
      (if (not= (type id) :string)
          (report :error where "workflowId must be a string")
          (external? id)
          (report :error where (.. "workflows of other Arazzo documents are not supported: "
                                   id))
          (not (. workflows id))
          (report :error where (.. "unknown workflow '" id "'"))))

    (fn input-names [wf]
      "The names of wf's inputs, or nil when its schema doesn't list them."
      (let [(ok schema) (pcall arazzo.workflow-inputs doc wf)]
        (when (and ok (= (type schema) :table)
                   (= (type schema.properties) :table))
          (keys-of schema.properties))))

    (fn output-names [step]
      "The names of step's outputs: its own, else a workflow step's workflow's;
nil when unknown."
      (if (= (type step.outputs) :table) (keys-of step.outputs)
          (= (type step.workflowId) :string)
          (when (not (external? step.workflowId))
            (keys-of (?. workflows step.workflowId :outputs))) {}))

    (fn check-reference [scope where e]
      "Report what expression e refers to that doesn't exist."
      (let [(ok err) (pcall expr.resolve-expr empty-ctx e)]
        (when (not ok)
          (report :error where (tostring err))))
      (let [name #(e:match (.. "^%$" $ "%.([^#]+)"))]
        (match (e:match "^%$(%a+)")
          :inputs (let [input (name :inputs)
                        names (input-names scope.wf)]
                    (when (and input names (not (. names input)))
                      (report :error where
                              (.. "no input '" input "' in workflow "
                                  scope.wf.workflowId))))
          :steps (let [(id part rest) (e:match "^%$steps%.([^%.]+)%.(%a+)(.*)$")
                       target (when id (. scope.steps id))]
                   (if (and id (not target))
                       (report :error where (.. "unknown step '" id "'"))
                       (and target (= part :outputs))
                       (let [output (rest:match "^%.([^#]+)")
                             names (output-names target)]
                         (when (and output names (not (. names output)))
                           (report :error where
                                   (.. "step '" id "' has no output '" output
                                       "'"))))))
          :workflows (let [(id part rest) (e:match "^%$workflows%.([^%.]+)%.(%a+)(.*)$")
                           target (when id (. workflows id))]
                       (if (and id (not target))
                           (report :error where
                                   (.. "unknown workflow '" id "'"))
                           (and target (= part :outputs))
                           (let [output (rest:match "^%.([^#]+)")]
                             (when (and output
                                        (not (. (keys-of target.outputs) output)))
                               (report :error where
                                       (.. "workflow '" id "' has no output '"
                                           output "'"))))))
          :outputs (let [output (name :outputs)]
                     (when (and output
                                (not (. (keys-of scope.wf.outputs) output)))
                       (report :error where
                               (.. "workflow " scope.wf.workflowId
                                   " has no output '" output "'"))))
          :sourceDescriptions (let [source (e:match "^%$sourceDescriptions%.([^%.]+)")]
                                (when (and source (not (. sources source)))
                                  (report :error where
                                          (.. "unknown source '" source "'")))))))

    (fn check-value [scope where v]
      "Check the expressions anywhere in v: a string, a Selector Object or
data holding them."
      (if (= (type v) :string)
          (each [_ e (ipairs (expressions-in v))]
            (check-reference scope where e))
          (expr.selector-object? v)
          (do
            (check-value scope where v.context)
            (let [(ok kind) (pcall expr.expression-type v.type)]
              (if (not ok) (report :error where (tostring kind))
                  (and (= kind :jsonpath) (not (v.selector:find "{$" 1 true)))
                  (let [(ok err) (pcall jsonpath.compile v.selector)]
                    (when (not ok)
                      (report :error where (tostring err)))))))
          (and (= (type v) :table) (not= v json.null))
          (each [_ item (pairs v)]
            (check-value scope where item))))

    (fn check-criteria [scope where criteria]
      (each [_ c (ipairs (if (list-of-tables? criteria) criteria []))]
        (let [condition (tostring c.condition)
              (ok kind) (pcall expr.expression-type (or c.type :simple))
              ;; runtime expressions inside are only known when running
              embedded (condition:find "{$" 1 true)]
          (if (not ok) (report :error where (tostring kind)) (= kind :simple)
              (let [(_ problem) (expr.eval-criterion empty-ctx c)]
                (if problem (report :error where problem)
                    (each [_ e (ipairs (expr.condition-expressions condition))]
                      (check-reference scope where e))))
              (do
                (check-value scope where c.context)
                (each [_ e (ipairs (expressions-in condition))]
                  (check-reference scope where e))
                (when (not embedded)
                  (let [(ok err) (pcall (if (= kind :regex)
                                            #(iregexp.compile condition
                                                              {:ecmascript true})
                                            #(jsonpath.compile condition)))]
                    (when (not ok)
                      (report :error where (tostring err))))))))))

    (fn expand [where items]
      "items with their references replaced by the components they name."
      (icollect [_ item (ipairs (if (list? items) items []))]
        (if (and (= (type item) :table) (= (type item.reference) :string))
            (let [target (component doc item.reference)]
              (if target
                  (if (= nil item.value) target
                      (doto (collect [k v (pairs target)] k v)
                        (tset :value item.value)))
                  (report :error where (.. "unknown component " item.reference))))
            item)))

    (fn check-actions [scope where-of actions]
      (each [_ a (ipairs actions)]
        (when (= (type a) :table)
          (let [where (where-of a)]
            (match a.type
              :end nil
              (where (or :goto :retry)) (do
                                          (when (and (not= nil a.stepId)
                                                     (not (. scope.steps
                                                             a.stepId)))
                                            (report :error where
                                                    (.. a.type
                                                        " to unknown step '"
                                                        (tostring a.stepId) "'")))
                                          (when (not= nil a.workflowId)
                                            (check-workflow-id where
                                                               a.workflowId))
                                          (when (and (= a.type :goto)
                                                     (= nil a.stepId)
                                                     (= nil a.workflowId))
                                            (report :error where
                                                    "goto needs a stepId or a workflowId")))
              _ (report :error where "type must be end, goto or retry"))
            (check-criteria scope where a.criteria)
            (each [_ p (ipairs (if (list-of-tables? a.parameters) a.parameters
                                   []))]
              (check-value scope where p.value))))))

    (fn from-profile? [location name]
      "Whether the profile supplies parameter name in location."
      (not= nil
            (?. supplied location (if (= location :header) (name:lower) name))))

    (fn check-operation [where op params body]
      "Report what step's parameters and body get wrong about operation op."
      (let [ignored? #(and (= $1 :header) (. ignored-headers ($2:lower)))
            declared (collect [_ p (ipairs (or op.parameters []))]
                       (when (and (= (type p.name) :string)
                                  (= (type p.in) :string)
                                  (not (ignored? p.in p.name)))
                         (values (param-key p.in p.name) p)))
            given (collect [_ p (ipairs params)]
                    (when (and (= (type p.name) :string)
                               (= (type p.in) :string))
                      (values (param-key p.in p.name) true)))
            name (or op.operation-id op.name "the operation")]
        (each [_ path-param (ipairs (or op.path-params []))]
          (let [key (param-key :path path-param)]
            (tset declared key
                  (or (. declared key)
                      {:name path-param :in :path :required true}))))
        (each [key p (pairs declared)]
          (when (and (or p.required (= p.in :path)) (not (. given key))
                     (not (from-profile? p.in p.name)))
            (report :error where
                    (.. "required " p.in " parameter '" p.name "' is missing"))))
        (each [_ p (ipairs params)]
          (when (and (= (type p.name) :string) (. locations p.in)
                     (not= p.in :querystring) (not (ignored? p.in p.name))
                     (not (. declared (param-key p.in p.name))))
            (report :warning where
                    (.. name " has no " p.in " parameter '" p.name "'"))))
        (if (and body (not op.has-body))
            (report :warning where (.. name " takes no request body"))
            (and (not body) (?. op :spec :requestBody :required))
            (report :error where (.. name " requires a request body")))))

    (fn check-target [where step params]
      "Report what step calls that doesn't exist, or what its call gets wrong."
      (let [targets (accumulate [n 0 _ k (ipairs [:operationId
                                                  :operationPath
                                                  :workflowId])]
                      (if (not= nil (. step k)) (+ n 1) n))]
        (if (= targets 0)
            (report :error where
                    "calls nothing: give an operationId, operationPath or workflowId")
            (> targets 1)
            (report :error where
                    "calls both an operation and a workflow: give only one")
            (not= nil step.workflowId)
            (check-workflow-id where step.workflowId)
            (and (not= nil step.operationId)
                 (not= (type step.operationId) :string))
            (report :error where "operationId must be a string")
            (and (not= nil step.operationPath)
                 (not= (type step.operationPath) :string))
            (report :error where "operationPath must be a string")
            (let [ref (or step.operationId step.operationPath)
                  (ok op) (pcall #(if step.operationId
                                      (arazzo.find-op-by-id clients
                                                            (expr.eval empty-ctx
                                                                       step.operationId))
                                      (arazzo.find-op-by-path clients
                                                              step.operationPath)))]
              (if (not ok) (report :error where (tostring op)) (not op)
                  (report :error where (.. "operation not found: " ref))
                  (check-operation where op params step.requestBody))))))

    (fn check-step [scope step where]
      (let [params (icollect [_ p (ipairs (expand where
                                                  (doto (icollect [_ p (ipairs scope.wf-params)]
                                                          p)
                                                    (#(each [_ p (ipairs (if (list? step.parameters)
                                                                             step.parameters
                                                                             []))]
                                                        (table.insert $ p))))))]
                     (when (= (type p) :table) p))]
        (check-target where step params)
        (each [_ p (ipairs params)]
          (when (and (not (. locations p.in)) (= nil step.workflowId))
            (report :error where
                    (.. "parameter '" (tostring p.name)
                        "': 'in' must be path, query, header, cookie or querystring")))
          (check-value scope where p.value))
        (when (= (type step.requestBody) :table)
          (check-value scope where step.requestBody.payload)
          (each [_ r (ipairs (if (list-of-tables? step.requestBody.replacements)
                                 step.requestBody.replacements
                                 []))]
            (check-value scope where r.value)))
        (check-criteria scope where step.successCriteria)
        (each [_ kind (ipairs [:onSuccess :onFailure])]
          (check-actions scope
                         #(.. where " › " kind " " (tostring (or $.name "")))
                         (expand where (. step kind))))
        (when (= (type step.outputs) :table)
          (each [_ v (pairs step.outputs)]
            (check-value scope where v)))))

    (fn check-workflow [wf]
      (let [where (tostring wf.workflowId)
            steps {}
            step-list (if (list-of-tables? wf.steps) wf.steps [])]
        (when (not (list-of-tables? wf.steps))
          (report :error where "steps must be a list of steps"))
        (each [i step (ipairs step-list)]
          (if (not= (type step.stepId) :string)
              (report :error (.. where " › step " i) "needs a stepId")
              (. steps step.stepId)
              (report :error (.. where " › step " step.stepId)
                      "stepId used twice")
              (tset steps step.stepId step)))
        (if (and (not= nil wf.dependsOn)
                 (not (and (list? wf.dependsOn)
                           (accumulate [ok true _ d (ipairs wf.dependsOn)
                                        &until (not ok)]
                             (= (type d) :string)))))
            (report :error where "dependsOn must list workflow ids")
            (each [_ dep (ipairs (or wf.dependsOn []))]
              (if (external? dep)
                  (report :error where
                          (.. "workflows of other Arazzo documents are not supported: "
                              dep))
                  (not (. workflows dep))
                  (report :error where
                          (.. "depends on unknown workflow '" dep "'")))))
        (let [args (. wf :x-ezu-args)
              inputs (input-names wf)]
          (if (and (not= nil args)
                   (not (and (list? args)
                             (accumulate [ok true _ a (ipairs args)
                                          &until (not ok)]
                               (= (type a) :string)))))
              (report :error where "x-ezu-args must list input names")
              (let [seen {}]
                (each [_ a (ipairs (or args []))]
                  (when (and inputs (not (. inputs a)))
                    (report :error where
                            (.. "x-ezu-args names '" a
                                "', which isn't an input")))
                  (when (. seen a)
                    (report :error where (.. "x-ezu-args names '" a "' twice")))
                  (tset seen a true)))))
        (let [scope {: wf
                     : steps
                     :wf-params (if (list? wf.parameters) wf.parameters [])}]
          (each [_ step (ipairs step-list)]
            (when (= (type step.stepId) :string)
              (check-step scope step (.. where " › step " step.stepId))))
          ;; the workflow's own actions apply after any step: checked once
          (each [_ kind (ipairs [:successActions :failureActions])]
            (check-actions scope
                           #(.. where " › " kind " "
                                (tostring (or $.name "")))
                           (expand where (. wf kind))))
          (when (= (type wf.outputs) :table)
            (each [_ v (pairs wf.outputs)]
              (check-value scope where v))))))

    (let [seen {}]
      (each [i wf (ipairs (if (list? doc.workflows) doc.workflows []))]
        (if (not (and (= (type wf) :table) (= (type wf.workflowId) :string)))
            (report :error (.. "workflow " i) "needs a workflowId")
            (. seen wf.workflowId)
            (report :error wf.workflowId "workflowId used twice")
            (do
              (tset seen wf.workflowId true)
              (check-workflow wf)))))
    problems))

(fn check [doc clients ?supplied]
  "What is wrong in Arazzo document doc, whose sources are clients, found
without running it: [{:level :error|:warning :where :message}]. ?supplied:
{:header {name true} :query {name true}}, the parameters every request gets
anyway (from a profile), header names lowercased."
  (checker doc clients (or ?supplied {})))

{: check}
