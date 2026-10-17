;; ABOUTME: Executes Arazzo 1.0 and 1.1 workflows: resolves source clients and
;; ABOUTME: operations, runs steps, evaluates criteria and applies actions.
(local ezu (require :ezu))

(local expr (require :ezu.arazzo.expr))

(local json (require :ezu.json))

(local yaml (require :ezu.yaml))

(local http-mod (require :ezu.http))

(local socket (require :socket))

(local util (require :ezu.util))
(local retry (require :ezu.retry))

(local refs (require :ezu.refs))

(local jsonpath (require :ezu.jsonpath))

;; ---- loading ----

;; where each loaded document came from and how it was fetched
;; ({:location :ssl :timeout}), to resolve its relative $refs the same way
(local doc-sources (setmetatable {} {:__mode :k}))

(fn load-doc [path ?opts]
  "Load and parse an Arazzo document (JSON or YAML) from a local path or
http(s):// URL. ?opts: {:ssl :timeout}, also used for the documents it
refers to."
  (let [fetch-opts {:ssl (?. ?opts :ssl) :timeout (?. ?opts :timeout)}
        (ok parsed) (pcall yaml.decode (http-mod.fetch-text path fetch-opts))]
    (assert ok (.. "failed to parse arazzo document: " (tostring parsed)))
    (let [version (?. parsed :arazzo)]
      (when (not (and (= (type version) :string)
                      (or (version:match "^1%.0%.") (version:match "^1%.1%."))))
        (error (.. "Arazzo version " (tostring version)
                   " is not supported (1.0 and 1.1 are)") 0)))
    (when (= (type parsed) :table)
      (tset doc-sources parsed
            {:location path :ssl fetch-opts.ssl :timeout fetch-opts.timeout}))
    parsed))

(fn base-uri [doc ?location]
  "The URI relative references in doc resolve against: its $self, itself
relative to where doc came from, else that location."
  (let [location (or ?location (?. doc-sources doc :location))
        self (. doc "$self")]
    (if (and self location) (util.resolve-reference location self)
        (or self location))))

(fn doc-resolver [doc]
  "$ref resolver for doc, references into other files resolved from its
location (no credentials are sent for them)."
  (let [source (or (. doc-sources doc) {})]
    (refs.resolver doc
                   {:base source.location
                    :load #(ezu.load-schema $
                                            {:ssl source.ssl
                                             :timeout source.timeout
                                             :credentials false})})))

;; ---- client building ----

(fn declared-server-variables [schema index]
  "Names of the variables of the schema's server at index and of the servers
path items and operations declare."
  (let [names {}
        add #(each [k (pairs (or (?. $ :variables) {}))]
               (tset names k true))]
    (add (?. schema :servers index))
    (each [_ item (pairs (or schema.paths {}))]
      (when (= (type item) :table)
        (each [_ server (ipairs (or item.servers []))]
          (add server))
        (each [_ op (pairs item)]
          (when (= (type op) :table)
            (each [_ server (ipairs (or op.servers []))]
              (add server))))))
    names))

(fn source-client [url opts server-vars used]
  "Client for one source, given only the server variables its schema
declares; records the variables it used in used."
  (if (= nil (next server-vars))
      (ezu.client url opts)
      (let [schema ((or opts.load-schema ezu.load-schema) url
                                                          {:ssl opts.ssl
                                                           :headers opts.headers
                                                           :timeout opts.timeout})
            declared (declared-server-variables schema (or opts.server-index 1))
            own (collect [name value (pairs server-vars)]
                  (when (. declared name)
                    (tset used name true)
                    (values name value)))
            client-opts (collect [k v (pairs opts)] k v)]
        (tset client-opts :server-vars own)
        (tset client-opts :source-url url)
        (ezu.client schema client-opts))))

(fn build-clients [doc ?opts ?location]
  "Returns {sourceName → ezu-client} for openapi sourceDescriptions.
Relative source URLs resolve against ?location, the document's own path or URL."
  (let [clients {}
        base (base-uri doc ?location)
        sources (icollect [_ src (ipairs (or doc.sourceDescriptions []))]
                  ;; type is optional: anything but arazzo and asyncapi is an
                  ;; OpenAPI source
                  (when (and (not= src.type :arazzo) (not= src.type :asyncapi))
                    src))]
    (when (and (?. ?opts :base-url) (> (length sources) 1))
      (error (.. "base-url override is ambiguous: the document has "
                 (length sources) " openapi sources") 0))
    (when (and (?. ?opts :server-index) (> (length sources) 1))
      (error (.. "server-index is ambiguous: the document has "
                 (length sources) " openapi sources") 0))
    (let [server-vars (or (?. ?opts :server-vars) {})
          used {}]
      (each [_ src (ipairs sources)]
        (let [url (if base (util.resolve-reference base src.url) src.url)
              (ok c) (pcall source-client url (or ?opts {}) server-vars used)]
          (when (not ok)
            (error (.. "source '" src.name "': " (tostring c)) 0))
          (tset clients src.name c)))
      (each [name (pairs server-vars)]
        (when (not (. used name))
          (error (.. "no openapi source declares server variable '" name "'") 0))))
    clients))

;; ---- operation lookup ----

(fn find-op [clients pred ?source]
  "First operation satisfying pred, searching only ?source when given."
  (accumulate [found nil name client (pairs clients) &until found]
    (when (or (= nil ?source) (= name ?source))
      (accumulate [op-found nil _ op (pairs client) &until op-found]
        (when (and (= (type op) :table) op.invoke (pred op))
          op)))))

(fn find-op-by-id [clients op-id]
  "Resolve an operationId, plain or $sourceDescriptions-qualified."
  (if (and (= (type op-id) :table) op-id.__source)
      ;; explicit source: $sourceDescriptions.name.opId
      (do
        (assert (. clients op-id.__source)
                (.. "unknown source '" op-id.__source "'"))
        (find-op clients #(= $.operation-id op-id.__operationId) op-id.__source))
      ;; plain string: must be unique across sources
      (let [sources (doto (icollect [name (pairs clients)]
                            (when (find-op clients #(= $.operation-id op-id)
                                           name)
                              name))
                      (table.sort))]
        (when (> (length sources) 1)
          (error (string.format "operationId '%s' is in several sources (%s): use $sourceDescriptions.NAME.%s"
                                op-id (table.concat sources ", ") op-id)
                 0))
        (find-op clients #(= $.operation-id op-id) (. sources 1)))))

(fn find-op-by-path [clients op-path-expr]
  "Resolve an operationPath expression to an operation.
Expression format: '{$sourceDescriptions.NAME.url}#/paths/~1foo/method'"
  (let [;; extract source name from {$sourceDescriptions.NAME.url} prefix
        src-name (op-path-expr:match "{%$sourceDescriptions%.([^%.}]+)%.[^}]+}")
        ;; extract the JSON pointer fragment after #
        ptr (op-path-expr:match "#(.+)$")]
    (assert src-name (.. "operationPath: cannot parse source name from: "
                         op-path-expr))
    (assert ptr (.. "operationPath: missing # fragment in: " op-path-expr))
    (assert (. clients src-name) (.. "operationPath: unknown source '" src-name
                                     "'"))
    ;; pointer is /paths/~1foo~1{id}/method — split into segments
    ;; a URI fragment: percent-escapes are decoded before pointer escapes
    (let [segs (icollect [seg (ptr:gmatch "[^/]+")]
                 (util.percent-decode seg))]
      ;; segs[1]="paths", segs[2]=encoded-path, segs[3]=method
      (assert (and (= (. segs 1) "paths") (. segs 2) (. segs 3))
              (.. "operationPath: expected /paths/<path>/<method>, got: " ptr))
      (let [api-path (util.unescape-pointer (. segs 2))
            method (: (. segs 3) :lower)]
        (find-op clients #(and (= $.path api-path) (= $.method method))
                 src-name)))))

;; ---- parameter resolution ----

(fn resolve-params [ctx params]
  "Evaluate parameters into {:path {} :query {} :headers {}} keyed by name."
  (let [result {:headers {} :path {} :query {}}
        cookies []]
    (each [_ p (ipairs params)]
      (let [raw (expr.eval ctx p.value) ;; a null value is no value
            v (when (not= raw json.null) raw)]
        (match (when (not= nil v) p.in)
          :path (tset result.path p.name v)
          :query (tset result.query p.name v)
          :header (tset result.headers (p.name:lower) v)
          :querystring (tset result :querystring (tostring v))
          :cookie (table.insert cookies
                                (.. p.name "="
                                    (tostring (http-mod.header-value (.. "cookie "
                                                                         p.name)
                                                                     v)))))))
    (when (next cookies)
      (tset result.headers :cookie (table.concat cookies "; ")))
    result))

(fn slot [node k pointer]
  "The key of node that pointer segment k names: arrays take a 0-based index,
or - for the end (RFC 6901)."
  (if (not (json.array? node)) k (= k "-") (+ 1 (length node))
      (k:match "^%d+$") (+ 1 (tonumber k))
      (error (.. "replacement target " pointer ": '" k
                 "' is not an array index") 0)))

(fn set-at-pointer [value pointer new]
  "value with the location named by JSON pointer set to new (objects along the
way are created)."
  (let [keys (icollect [k (pointer:gmatch "/([^/]*)")]
               (util.unescape-pointer k))
        last (table.remove keys)]
    (assert last (.. "replacement target must be a JSON pointer: " pointer))
    (var node value)
    (each [_ k (ipairs keys)]
      (let [key (slot node k pointer)]
        ;; null (shared and read-only) is replaced, like any non-object
        (when (or (not= (type (. node key)) :table) (= (. node key) json.null))
          (tset node key {}))
        (set node (. node key))))
    (tset node (slot node last pointer) new)
    value))

(fn set-at-path [value path new]
  "value with the node at path (member names and 0-based indexes, as JSONPath
gives them) set to new."
  (var node value)
  (for [i 1 (- (length path) 1)]
    (let [k (. path i)]
      (set node (. node (if (= (type k) :number) (+ k 1) k)))))
  (let [k (. path (length path))]
    (if (= nil k) new (do
                        (tset node (if (= (type k) :number) (+ k 1) k) new)
                        value))))

(fn replace [body r value]
  "body with replacement r's value set at its target: a JSON Pointer, or with
targetSelectorType jsonpath every node the query selects."
  (match (expr.expression-type (or r.targetSelectorType :jsonpointer))
    :jsonpointer (set-at-pointer body r.target value)
    :jsonpath (let [nodes (jsonpath.query r.target body)]
                (when (= nil (next nodes))
                  (error (.. "replacement target " r.target " selects nothing")
                         0))
                (accumulate [b body _ node (ipairs nodes)]
                  (set-at-path b node.path value)))
    kind (error (.. "a replacement target can't be of type " kind) 0)))

(fn copy [v]
  "A deep copy of decoded JSON v, arrays still arrays."
  (if (or (not= (type v) :table) (= v json.null)) v
      (setmetatable (collect [k x (pairs v)] k (copy x)) (getmetatable v))))

(fn request-body [ctx request-body]
  "The step's body: the evaluated payload with its replacements applied (to
a copy: the payload may be an input or another step's data)."
  (let [body (copy (expr.eval ctx request-body.payload))]
    (accumulate [b body _ r (ipairs (or request-body.replacements []))]
      (do
        (assert (= (type b) :table)
                "requestBody replacements need a structured payload")
        (replace b r (expr.eval ctx r.value))))))

(fn resolve-outputs [ctx outputs]
  (let [result {}]
    (each [k expr-str (pairs (or outputs {}))]
      (tset result k (expr.eval ctx expr-str)))
    result))

;; ---- step execution ----

(fn execute-step [ctx clients step params on-running]
  "Execute a single step with resolved parameter objects. Updates ctx in place;
on-running is called with the operation reference just before the request.
Returns the response, or (nil message) when the request failed in transport."
  (let [step-id step.stepId
        resolved (resolve-params ctx params)
        body (when step.requestBody
               (request-body ctx step.requestBody))
        op-ref (or step.operationId step.operationPath)
        op (if step.operationId
               (find-op-by-id clients (expr.eval ctx step.operationId))
               (find-op-by-path clients step.operationPath))
        request {:body body
                 :headers (doto resolved.headers
                            (tset :content-type
                                  (?. step :requestBody :contentType)))
                 :path resolved.path
                 :query (when (next resolved.query) resolved.query)
                 :querystring resolved.querystring
                 ;; milliseconds in Arazzo, seconds for requests
                 :timeout (when step.timeout (/ step.timeout 1000))}]
    (when (not op)
      (error (.. "step '" step-id "': operation not found: " (tostring op-ref))))
    (tset request :method (op.method:upper))
    (tset request :url (op.url-for request))
    (on-running op-ref)
    (let [t0 (socket.gettime)
          (ok resp) (pcall op.invoke request)
          elapsed (- (socket.gettime) t0)]
      ;; store in context; a transport failure leaves no response
      (tset ctx.steps step-id
            {:elapsed elapsed
             :op-ref op-ref
             :outputs {}
             :request request
             :response (when ok resp)})
      ;; update current response/request in ctx for criterion eval
      (tset ctx :response (when ok resp))
      (tset ctx :request request)
      (if ok
          resp
          (values nil (.. "request failed: " (tostring resp)))))))

;; ---- workflow execution ----

(fn expand-reference [doc item]
  "Replace a Reusable Object {:reference \"$components.KIND.NAME\"} with its
target; a :value on the reference overrides the target parameter's value."
  (if (and (= (type item) :table) item.reference)
      (let [(kind name) (item.reference:match "^%$components%.([^%.]+)%.(.+)$")
            target (?. doc :components kind name)]
        (assert target (.. "unresolved reference: " item.reference))
        (if (= nil item.value)
            target
            (doto (collect [k v (pairs target)] k v)
              (tset :value item.value))))
      item))

(fn expand-references [doc items]
  (icollect [_ item (ipairs (or items []))]
    (expand-reference doc item)))

(fn merge-actions [workflow-actions step-actions]
  "Step actions first, then workflow actions not overridden by name."
  (let [overridden (collect [_ a (ipairs step-actions)]
                     (when a.name (values a.name true)))
        out (icollect [_ a (ipairs step-actions)] a)]
    (each [_ a (ipairs workflow-actions)]
      (when (not (and a.name (. overridden a.name)))
        (table.insert out a)))
    out))

;; response bodies longer than this are cut in failure messages
(local message-body-length 500)

(fn failure-message [step-id outcome failure]
  "Why step-id failed: its error, or the criterion that failed with the
response's status and body. A failed sub-workflow's reason follows the step
and the workflow it ran: step 'find' (lookup) › step 'list' failed: …"
  (if (and outcome.error outcome.workflow)
      (.. "step '" step-id "' (" outcome.workflow ") › "
          (tostring outcome.error))
      outcome.error
      (.. "step '" step-id "' failed: " (tostring outcome.error))
      (let [resp outcome.response
            b (?. resp :body)
            body (if (= nil b) "" (= (type b) :string)
                     (.. " " (expr.cut b message-body-length))
                     (.. " " (expr.brief b message-body-length)))]
        (.. "step '" step-id "' failed: " (tostring failure) "; HTTP "
            (tostring (or (?. resp :status) "?")) body))))

(fn find-workflow [doc workflow-id]
  "The workflow with workflow-id in doc, or nil."
  (accumulate [found nil _ wf (ipairs (or doc.workflows [])) &until found]
    (when (= wf.workflowId workflow-id) wf)))

(fn enter-workflow [workflow-id ?opts]
  "?opts with workflow-id pushed on the running-workflow stack; a workflow
already on the stack means a cycle (dependsOn or a step calling itself)."
  (let [stack (or (?. ?opts :workflow-stack) [])]
    (each [_ active (ipairs stack)]
      (when (= active workflow-id)
        (error (.. "workflow cycle: " (table.concat stack " -> ") " -> "
                   workflow-id) 0)))
    (doto (collect [k v (pairs (or ?opts {}))]
            k
            v)
      (tset :workflow-stack
            (doto (icollect [_ w (ipairs stack)] w)
              (table.insert workflow-id))))))

(fn emit [run event]
  "Pass event to the run's on-step callback, with the workflow and its depth."
  (when run.on-step
    (set event.workflow run.wf.workflowId)
    (set event.depth run.depth)
    (run.on-step event)))

(fn calls [step]
  "What step calls: an operation, or a workflow."
  (if step.workflowId :workflow :operation))

(fn step-event [run step status]
  "An on-step event about step, at its current attempt."
  {: status
   :step step.stepId
   :index (. run.step-index step.stepId)
   :count (length run.steps)
   :attempt (. run.attempts step.stepId)
   :calls (calls step)})

(fn op-ref-of [step]
  (or step.operationId step.operationPath step.workflowId))

(fn run-step [run step]
  "Run one step; returns {:ok bool :response resp :error message}, and
:workflow, the workflow a failed sub-workflow step ran."
  (tset run.attempts step.stepId (+ 1 (or (. run.attempts step.stepId) 0)))
  (if step.workflowId
      ;; sub-workflow step: its outputs become the step's outputs
      (let [sub-inputs (collect [_ p (ipairs (expand-references run.doc
                                                                step.parameters))]
                         p.name
                         (expr.eval run.ctx p.value))
            _ (emit run
                    (doto (step-event run step :running)
                      (tset :op-ref step.workflowId)))
            t0 (socket.gettime)
            (ok sub) (pcall run.run-sub step.workflowId sub-inputs)]
        ;; the step has no response of its own: criteria must not see the
        ;; previous step's
        (tset run.ctx :response nil)
        (tset run.ctx :request nil)
        (tset run.ctx.steps step.stepId
              {:elapsed (- (socket.gettime) t0)
               :op-ref step.workflowId
               :outputs (if ok sub.outputs {})
               :request nil
               :response nil})
        (if ok {:ok true} {:ok false :error sub :workflow step.workflowId}))
      ;; operation step: merge workflow params then step params
      (let [step-params (expand-references run.doc step.parameters)
            _ (each [_ p (ipairs step-params)]
                (when (. p "$ref")
                  (error (.. "step '" step.stepId
                             "': refer to reusable parameters with reference: $components.parameters.NAME, not $ref")
                         0))
                (when (= nil p.in)
                  (error (.. "step '" step.stepId "': parameter '"
                             (tostring p.name)
                             "' has no 'in' (path, query, header or cookie)")
                         0)))
            params (util.merge-parameters run.wf-params step-params)]
        (match (execute-step run.ctx run.clients step params
                             #(emit run
                                    (doto (step-event run step :running)
                                      (tset :op-ref $))))
          resp {:ok true :response resp}
          (nil message) {:ok false :error message}))))

(fn finish-step [run step outcome]
  "Check step's success criteria after it ran, resolve its outputs and report
it: (passed failure), failure saying which criterion didn't pass."
  (let [failing (when outcome.ok
                  (expr.failing-criterion run.ctx step.successCriteria))
        passed (and outcome.ok (= nil failing))
        failure (when failing (expr.explain-criterion run.ctx failing))
        record (. run.ctx.steps step.stepId)]
    (when step.outputs
      (tset record :outputs (resolve-outputs run.ctx step.outputs)))
    (when passed
      (tset run.retry-counts step.stepId nil))
    (emit run (doto (step-event run step :done)
                (tset :op-ref (or (?. record :op-ref) (op-ref-of step)))
                (tset :elapsed (?. record :elapsed))
                (tset :response outcome.response)
                (tset :outputs (?. record :outputs))
                (tset :passed passed)
                (tset :failure failure)
                (tset :error outcome.error)))
    (values passed failure)))

(fn retry-wait [run seconds]
  "Seconds to wait before running a step again: the response's Retry-After
(seconds or a date, at most run.max-wait) overrules the action's retryAfter,
as the Arazzo spec recommends."
  (let [asked (retry.retry-after run.ctx.response os.time)]
    (if asked (math.min run.max-wait asked) seconds)))

(fn take-action [run step action ?wait]
  "Report the action taken after step, then wait ?wait seconds."
  (emit run (doto (step-event run step :action)
              (tset :action action)
              (tset :wait (or ?wait 0))))
  (when (and ?wait (> ?wait 0))
    (socket.sleep ?wait)))

(fn run-step-first [run step-id retried]
  "Run the step a retry action names before the retried step runs again; it
must succeed."
  (let [target (. run.steps
                  (or (. run.step-index step-id)
                      (error (.. "retry: unknown step: " step-id) 0)))
        outcome (run-step run target)
        (passed failure) (finish-step run target outcome)]
    (when (not passed)
      (error (.. "step '" retried.stepId "': retry step "
                 (failure-message step-id outcome failure)) 0))))

(fn action-inputs [run action]
  "The inputs of the workflow an action goes to: its parameters, else the
current workflow's inputs."
  (if action.parameters
      (collect [_ p (ipairs (expand-references run.doc action.parameters))]
        p.name
        (expr.eval run.ctx p.value))
      run.inputs))

(fn goto-action [run action step]
  "Index of the step a goto action continues at."
  (let [target (or action.stepId action.workflowId)
        n (+ 1 (or (. run.goto-counts target) 0))]
    (tset run.goto-counts target n)
    (assert (<= n run.max-gotos) (.. "goto loop detected at: " target))
    ;; only going back to the same step waits: that's a polling loop
    (take-action run step action
                 (when (and action.stepId (= action.stepId step.stepId)
                            action.retryAfter)
                   (retry-wait run action.retryAfter)))
    (if action.stepId
        (or (. run.step-index action.stepId)
            (error (.. "goto: unknown step: " action.stepId) 0))
        (do
          (run.run-sub action.workflowId (action-inputs run action))
          (+ (length run.steps) 1)))))

(fn retry-action [run action i step]
  "i to run the step again, or nil once retryLimit is used up."
  (let [n (+ 1 (or (. run.retry-counts step.stepId) 0))]
    (when (<= n (or action.retryLimit 1))
      (tset run.retry-counts step.stepId n)
      (take-action run step action (retry-wait run action.retryAfter))
      (when action.workflowId
        (run.run-sub action.workflowId (action-inputs run action)))
      (when action.stepId
        (run-step-first run action.stepId step))
      i)))

(fn next-index [run i step success?]
  "Index of the step to run after step i, by the first action that applies;
nil when a failure is left unhandled."
  (let [wf run.wf
        actions (if success?
                    (merge-actions (expand-references run.doc wf.successActions)
                                   (expand-references run.doc step.onSuccess))
                    (merge-actions (expand-references run.doc wf.failureActions)
                                   (expand-references run.doc step.onFailure)))
        chosen (accumulate [found nil _ action (ipairs actions) &until found]
                 (when (expr.eval-criteria run.ctx action.criteria)
                   (match action.type
                     :end (do
                            (take-action run step action)
                            [(+ (length run.steps) 1)])
                     :goto [(goto-action run action step)]
                     :retry (match (retry-action run action i step)
                              again [again]))))]
    (if chosen (. chosen 1)
        success? (+ i 1)
        nil)))

(fn with-input-defaults [doc wf inputs]
  "inputs plus the default of each declared input that wasn't given."
  (let [given (collect [k v (pairs (or inputs {}))]
                k
                v)
        schema (when wf.inputs ((doc-resolver doc) wf.inputs))]
    (each [name prop (pairs (or (when (= (type schema) :table)
                                  schema.properties)
                                {}))]
      ;; OpenAPI 3.1 schemas may be booleans, which have no default
      (when (and (= nil (. given name)) (= (type prop) :table)
                 (not= nil prop.default))
        (tset given name prop.default)))
    given))

(fn check-steps [doc wf]
  "Raise for steps ezu can't run: AsyncAPI ones (sending and receiving
messages), and a dependsOn that sequential execution can't satisfy."
  (let [index (collect [i s (ipairs (or wf.steps []))]
                s.stepId
                i)
        async-sources (collect [_ src (ipairs (or doc.sourceDescriptions []))]
                        (when (= src.type :asyncapi) (values src.name true)))]
    (each [i step (ipairs (or wf.steps []))]
      (let [source (when (= (type step.operationId) :string)
                     (step.operationId:match "^%$sourceDescriptions%.([^%.]+)%."))]
        (when (or step.action step.channelPath step.correlationId
                  (and source (. async-sources source)))
          (error (.. "step '" (tostring step.stepId)
                     "': AsyncAPI steps are not supported") 0)))
      (each [_ dep (ipairs (or step.dependsOn []))]
        ;; steps of other workflows or documents are referred to with $
        (when (not (dep:match "^%$"))
          (let [j (or (. index dep)
                      (error (.. "step '" step.stepId
                                 "' depends on unknown step '" dep "'")
                             0))]
            (when (> j i)
              (error (.. "step '" step.stepId "' depends on step '" dep
                         "', which runs after it") 0))))))))

(fn run-workflow [doc workflow-id given-inputs clients ?opts]
  (let [wf (or (find-workflow doc workflow-id)
               (error (.. "workflow not found: " workflow-id) 0))
        opts (enter-workflow workflow-id ?opts)
        _ (check-steps doc wf)
        inputs (with-input-defaults doc wf given-inputs)
        ctx {:inputs inputs
             :request nil
             :response nil
             :steps {}
             :workflows {}
             :warn opts.warn
             :self (base-uri doc)
             :sources (collect [_ src (ipairs (or doc.sourceDescriptions []))]
                        src.name
                        src)}
        run {: doc
             : wf
             : clients
             : ctx
             : inputs
             :steps (or wf.steps [])
             :step-index (collect [i s (ipairs (or wf.steps []))]
                           s.stepId
                           i)
             :wf-params (expand-references doc wf.parameters)
             :on-step opts.on-step
             :depth (- (length opts.workflow-stack) 1)
             :attempts {}
             :max-gotos (or opts.max-gotos 50)
             :max-wait (or opts.max-wait 300)
             :goto-counts {}
             :retry-counts {}
             :run-sub (fn [sub-id sub-inputs]
                        (let [sub (run-workflow doc sub-id sub-inputs clients
                                                opts)]
                          (each [k v (pairs sub.ctx.workflows)]
                            (tset ctx.workflows k v))
                          (tset ctx.workflows sub-id
                                {:outputs sub.outputs :inputs sub.inputs})
                          sub))}
        step-order []]
    (emit run {:status :workflow
               :steps (icollect [_ step (ipairs run.steps)]
                        {:step step.stepId
                         :op-ref (op-ref-of step)
                         :calls (calls step)})})
    ;; workflows listed in dependsOn run first, once each, with the same inputs
    (each [_ dep (ipairs (or wf.dependsOn []))]
      (when (= nil (. ctx.workflows dep))
        (run.run-sub dep run.inputs)))
    (var i 1)
    (while (<= i (length run.steps))
      (let [step (. run.steps i)
            outcome (run-step run step)
            (success? failure) (finish-step run step outcome)]
        (table.insert step-order step.stepId)
        (set i
             (or (next-index run i step success?)
                 (error (failure-message step.stepId outcome failure) 0)))))
    ;; $outputs refers to the workflow's own outputs
    (set ctx.outputs {})
    (each [k v (pairs (or wf.outputs {}))]
      (tset ctx.outputs k (expr.eval ctx v)))
    {: ctx : inputs :outputs ctx.outputs :steps ctx.steps : step-order}))

;; ---- introspection ----

(fn positional-inputs [wf]
  "The inputs the CLI takes as positional arguments, in order: what the
workflow declares in x-ezu-args, an ezu extension."
  (let [declared (. wf :x-ezu-args)]
    (if (= (type declared) :table)
        (icollect [_ name (ipairs declared)]
          (when (= (type name) :string) name))
        [])))

(fn workflow-inputs [doc wf]
  "The workflow's inputs JSON Schema with $refs resolved, or nil."
  (when wf.inputs
    ((doc-resolver doc) wf.inputs)))

;; ---- public API ----

(fn run [path workflow-id inputs ?opts]
  "Load an Arazzo document and execute a workflow.
?opts: { clients, http-fn, ssl, headers, timeout, base-url, on-step, max-gotos,
max-wait (seconds a response's Retry-After may ask, default 300) }

on-step is called with events, each with :status, :workflow (its id) and
:depth (0, or 1 and more in workflows run by steps):
  :workflow  a workflow starts; :steps [{:step :op-ref :calls}]
  :running   a step's request is about to be sent
  :done      a step ran and its criteria were checked: :passed, :failure (the
             criterion that failed, with its values), :error (a request that
             failed in transport), :elapsed, :response, :outputs
  :action    an action applies after a step: :action, :wait (seconds)
Step events also have :step, :index, :count, :attempt (1, then 2… each time
the step runs again), :op-ref and :calls (:operation or :workflow)."
  (let [doc (load-doc path ?opts)
        client-opts (collect [k v (pairs (or ?opts {}))]
                      (when (not= k :on-step) (values k v)))
        clients (or (?. ?opts :clients) (build-clients doc client-opts path))]
    (run-workflow doc workflow-id (or inputs {}) clients ?opts)))

{:build-clients build-clients
 :find-op-by-id find-op-by-id
 :find-op-by-path find-op-by-path
 :load-doc load-doc
 :run run
 :run-workflow run-workflow
 :find-workflow find-workflow
 :positional-inputs positional-inputs
 :workflow-inputs workflow-inputs}
