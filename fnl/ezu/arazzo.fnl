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

(fn without-position [message]
  "message without the file:line: Lua puts before an error."
  (pick-values 1 (: (tostring message) :gsub "^[^%s:]+%.lua:%d+: " "")))

(fn load-doc [path ?opts]
  "Load and parse an Arazzo document (JSON or YAML) from a local path or
http(s):// URL. ?opts: {:ssl :timeout}, also used for the documents it
refers to. A local path is recorded without its . and .. segments, so a
document is the same whichever way it is reached."
  (let [fetch-opts {:ssl (?. ?opts :ssl) :timeout (?. ?opts :timeout)}
        path (if (path:match "^%a[%w+.-]*://") path
                 (util.normalize-segments path))
        (fetched text) (pcall http-mod.fetch-text path fetch-opts)
        _ (when (not fetched)
            (error (without-position text) 0))
        (ok parsed) (pcall yaml.decode text)]
    (when (not ok)
      (error (.. "failed to parse arazzo document: " (without-position parsed))
             0))
    (let [version (?. parsed :arazzo)]
      (when (not (and (= (type version) :string)
                      (or (version:match "^1%.0%.") (version:match "^1%.1%."))))
        (error (.. "Arazzo version " (tostring version)
                   " is not supported (1.0 and 1.1 are)") 0)))
    (when (= (type parsed) :table)
      (tset doc-sources parsed
            {:location path :ssl fetch-opts.ssl :timeout fetch-opts.timeout}))
    parsed))

(fn location [doc]
  "Where doc was loaded from, or nil."
  (?. doc-sources doc :location))

(fn base-uri [doc ?location]
  "The URI relative references in doc resolve against: its $self, itself
relative to where doc came from, else that location."
  (let [here (or ?location (location doc))
        self (. doc "$self")]
    (if (and self here) (util.resolve-reference here self) (or self here))))

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

(fn openapi-sources [doc]
  "doc's OpenAPI sources: its type is optional, and anything but arazzo and
asyncapi is one."
  (icollect [_ src (ipairs (or doc.sourceDescriptions []))]
    (when (and (not= src.type :arazzo) (not= src.type :asyncapi))
      src)))

(fn arazzo-sources? [doc]
  (accumulate [found false _ src (ipairs (or doc.sourceDescriptions []))
               &until found]
    (= src.type :arazzo)))

(fn build-clients [doc ?opts ?location]
  "Returns {sourceName → ezu-client} for openapi sourceDescriptions.
Relative source URLs resolve against ?location, the document's own path or URL.
?opts.source-clients, when given, keeps the clients built by URL so that each
is built once. ?opts.base-url and server-index apply to doc's one source, or
with ?opts.api-url to the sources at that URL only. Server variables no source
declares are refused, unless doc runs workflows of other documents (then the
run checks them against all) or ?opts.server-vars-elsewhere."
  (let [clients {}
        base (base-uri doc ?location)
        sources (openapi-sources doc)
        opts (or ?opts {})
        url-of #(if base (util.resolve-reference base $.url) $.url)
        overridden (icollect [_ src (ipairs sources)]
                     (when (or (= nil opts.api-url)
                               (= opts.api-url (url-of src)))
                       src))]
    (when (and opts.base-url (> (length overridden) 1))
      (error (.. "base-url override is ambiguous: the document has "
                 (length overridden) " openapi sources") 0))
    (when (and opts.server-index (> (length overridden) 1))
      (error (.. "server-index is ambiguous: the document has "
                 (length overridden) " openapi sources") 0))
    (let [server-vars (or opts.server-vars {})
          used {} ;; base-url and server-index are for one API: the others' own
          ;; servers stay
          plain (doto (collect [k v (pairs opts)] k v)
                  (tset :base-url nil)
                  (tset :server-index nil))]
      (each [_ src (ipairs sources)]
        (let [url (url-of src)
              cache opts.source-clients
              src-opts (if (or (= nil opts.api-url) (= opts.api-url url)) opts
                           plain)
              (ok c) (if (and cache (. cache url))
                         (values true (. cache url))
                         (let [own-used {}
                               (ok client) (pcall source-client url src-opts
                                                  server-vars own-used)]
                           (values ok (if ok {: client :used own-used} client))))]
          (when (not ok)
            (error (.. "source '" src.name "': " (tostring c)) 0))
          (each [name (pairs c.used)]
            (tset used name true))
          (when cache
            (tset cache url c))
          (tset clients src.name c.client)))
      (when (not (or opts.server-vars-elsewhere (= 0 (length sources))
                     (arazzo-sources? doc)))
        (each [name (pairs server-vars)]
          (when (not (. used name))
            (error (.. "no openapi source declares server variable '" name "'")
                   0)))))
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

(fn external-workflow [workflow-id]
  "The source and workflow id of $sourceDescriptions.SOURCE.WORKFLOW, a
workflow of another Arazzo document; nil for one of this document."
  (when (= (type workflow-id) :string)
    (workflow-id:match "^%$sourceDescriptions%.([^%.]+)%.(.+)$")))

(fn workflow-label [workflow-id]
  "workflow-id for people: SOURCE.WORKFLOW for another document's."
  (let [(source id) (external-workflow workflow-id)]
    (if source (.. source "." id) (tostring workflow-id))))

;; response bodies longer than this are cut in failure messages
(local message-body-length 500)

(fn failure-message [step-id outcome failure]
  "Why step-id failed: its error, or the criterion that failed with the
response's status and body. A failed sub-workflow's reason follows the step
and the workflow it ran: step 'find' (lookup) › step 'list' failed: …"
  (if (and outcome.error outcome.workflow)
      (.. "step '" step-id "' (" (workflow-label outcome.workflow) ") › "
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

(local fatal-meta {:__tostring #$.message})

(fn fail-run [message]
  "Raise message as a problem with the documents themselves (a source that
can't be used, a workflow that doesn't exist, a cycle): it fails the run,
whatever the steps' actions say."
  (error (setmetatable {: message :fatal true} fatal-meta) 0))

(fn fatal? [err]
  (= (getmetatable err) fatal-meta))

;; deeper than this, workflows running workflows are taken for a runaway
(local max-depth 64)

(fn find-workflow [doc workflow-id]
  "The workflow with workflow-id in doc, or nil."
  (accumulate [found nil _ wf (ipairs (or doc.workflows [])) &until found]
    (when (= wf.workflowId workflow-id) wf)))

(fn enter-workflow [key label ?opts]
  "?opts with the workflow key (its document and id) pushed on the
running-workflow stack, as label for people; a workflow already on the stack
means a cycle (dependsOn or a step calling itself)."
  (let [stack (or (?. ?opts :workflow-stack) [])
        keys (or (?. ?opts :workflow-keys) [])]
    (each [_ active (ipairs keys)]
      (when (= active key)
        (fail-run (.. "workflow cycle: " (table.concat stack " -> ") " -> "
                      label))))
    (when (>= (length stack) max-depth)
      (fail-run (.. "workflows nested more than " max-depth " deep: "
                    (table.concat stack " -> " 1 3) " -> … -> "
                    (table.concat stack " -> " (- (length stack) 2)) " -> "
                    label)))
    (doto (collect [k v (pairs (or ?opts {}))]
            k
            v)
      (tset :workflow-label nil)
      (tset :workflow-keys (doto (icollect [_ k (ipairs keys)] k)
                             (table.insert key)))
      (tset :workflow-stack (doto (icollect [_ w (ipairs stack)] w)
                              (table.insert label))))))

(fn emit [run event]
  "Pass event to the run's on-step callback, with the workflow and its depth."
  (when run.on-step
    (set event.workflow run.label)
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
        (if ok {:ok true} (fatal? sub)
            (fail-run (.. "step '" step.stepId "' ("
                          (workflow-label step.workflowId) ") › " sub.message))
            {:ok false :error sub :workflow step.workflowId}))
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

;; ---- workflows of other Arazzo documents ----

(fn place [url]
  "Where url is, to compare documents: :file for a local path, the origin of
an http(s) URL, nil for anything else."
  (if (url:match "^%a[%w+.-]*:") (util.origin url) :file))

(fn next-to? [location reference url]
  "Whether reference, resolved to url, is a relative reference that stays
where the document at location is: local files, or the same origin."
  (let [here (place location)]
    (and (not (reference:match "^%a[%w+.-]*:"))
         (not (reference:match "^[/~\\]")) (not= nil here) (= here (place url)))))

(fn source-url [doc source-name ?opts]
  "Where the Arazzo document doc's source source-name is. Unless
?opts.trust-sources, it must be next to doc: a relative reference staying
among local files, or on doc's origin, $self included."
  (let [src (accumulate [found nil _ s (ipairs (or doc.sourceDescriptions []))
                         &until found]
              (when (= s.name source-name) s))]
    (when (not src)
      (fail-run (.. "unknown source '" source-name "'")))
    (when (not= src.type :arazzo)
      (fail-run (.. "source '" source-name "' is not an Arazzo document")))
    (when (not= (type src.url) :string)
      (fail-run (.. "source '" source-name "': its url must be a string")))
    (let [here (or (location doc) "./")
          base (base-uri doc)
          url (if base (util.resolve-reference base src.url) src.url)]
      (when (not (or (?. ?opts :trust-sources) (next-to? here src.url url)))
        (fail-run (.. "Arazzo source '" source-name
                      "' is not next to the document (" src.url
                      (if (= url src.url) "" (.. ", at " url))
                      "); it is only loaded with trust-sources")))
      url)))

(fn check-server-variables [doc opts]
  "Raise for a server variable that no OpenAPI source of doc, or of the
documents its workflows can reach through Arazzo sources, declares. Sources
that can't be read are left to the steps that use them."
  (let [declared {}
        seen {}
        queue [doc]]
    (while (next queue)
      (let [d (table.remove queue 1)
            base (base-uri d)]
        (each [_ src (ipairs (openapi-sources d))]
          (let [url (if base (util.resolve-reference base src.url) src.url)]
            (when (not (. seen url))
              (tset seen url true)
              (let [(ok schema) (pcall (or opts.load-schema ezu.load-schema)
                                       url
                                       {:ssl opts.ssl
                                        :headers opts.headers
                                        :timeout opts.timeout})]
                (when ok
                  (each [name (pairs (declared-server-variables schema
                                                                (or opts.server-index
                                                                    1)))]
                    (tset declared name true)))))))
        (each [_ src (ipairs (or d.sourceDescriptions []))]
          (when (= src.type :arazzo)
            (let [(ok url) (pcall source-url d src.name opts)]
              (when (and ok (not (. seen url)))
                (tset seen url true)
                (let [(loaded sub) (pcall load-doc url opts)]
                  (when loaded
                    (table.insert queue sub)))))))))
    (each [name (pairs (or opts.server-vars {}))]
      (when (not (. declared name))
        (error (.. "no openapi source declares server variable '" name "'") 0)))))

(fn arazzo-source [doc source-name opts]
  "{:doc :clients :url} of the Arazzo document doc's source source-name, loaded
once per run (opts.arazzo-documents, by URL); see source-url."
  (let [url (source-url doc source-name opts)]
    (when (not opts.arazzo-documents)
      (set opts.arazzo-documents {}))
    (or (. opts.arazzo-documents url)
        (let [(loaded sub) (pcall load-doc url opts)
              _ (when (not loaded)
                  (fail-run (.. "source '" source-name "': " (tostring sub))))
              client-opts (collect [k v (pairs opts)]
                            (when (not= k :on-step) (values k v)))
              entry {:doc sub
                     : url
                     :clients (build-clients sub
                                             (doto client-opts
                                               (tset :server-vars-elsewhere
                                                     true))
                                             url)}]
          (tset opts.arazzo-documents url entry)
          entry))))

(fn workflow-key [doc workflow-id]
  "What tells a workflow from all others: its document's location and its id."
  (.. (or (location doc) (tostring doc)) "#" workflow-id))

(fn run-workflow [doc workflow-id given-inputs clients ?opts]
  (let [label (or (?. ?opts :workflow-label) workflow-id)
        wf (or (find-workflow doc workflow-id)
               (fail-run (.. "workflow not found: " label)))
        opts (enter-workflow (workflow-key doc workflow-id) label ?opts)
        ;; documents and clients are shared by the workflows the run runs
        _ (when (not opts.arazzo-documents)
            ;; the run starts here: base-url and server-index are for this
            ;; document's API
            (when (or opts.base-url opts.server-index)
              (match (openapi-sources doc)
                [src nil] (set opts.api-url
                               (let [base (base-uri doc)]
                                 (if base (util.resolve-reference base src.url)
                                     src.url)))))
            (when (and (next (or opts.server-vars {})) (arazzo-sources? doc))
              (check-server-variables doc opts))
            (set opts.arazzo-documents {})
            (match (location doc)
              url (tset opts.arazzo-documents url {: doc : clients : url})))
        _ (when (not opts.source-clients)
            (set opts.source-clients {}))
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
             : label
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
                        (let [(source id) (external-workflow sub-id)
                              other (when source
                                      (arazzo-source doc source opts))
                              sub (if other
                                      (run-workflow other.doc id sub-inputs
                                                    other.clients
                                                    (doto (collect [k v (pairs opts)]
                                                            k
                                                            v)
                                                      (tset :workflow-label
                                                            (workflow-label sub-id))))
                                      (run-workflow doc sub-id sub-inputs
                                                    clients opts))]
                          ;; another document's workflows are its own
                          (when (not other)
                            (each [k v (pairs sub.ctx.workflows)]
                              (tset ctx.workflows k v)))
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

{:arazzo-source arazzo-source
 :external-workflow external-workflow
 :location location
 :source-url source-url
 :build-clients build-clients
 :find-op-by-id find-op-by-id
 :find-op-by-path find-op-by-path
 :load-doc load-doc
 :run run
 :run-workflow run-workflow
 :find-workflow find-workflow
 :positional-inputs positional-inputs
 :workflow-inputs workflow-inputs}
