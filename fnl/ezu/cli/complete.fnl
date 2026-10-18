;; ABOUTME: Usage text, the option table, and shell completion: the __complete
;; ABOUTME: backend plus the fish, bash and zsh scripts that call it.
(local ezu (require :ezu))
(local arazzo (require :ezu.arazzo))
(local commands (require :ezu.arazzo.commands))
(local util (require :ezu.util))
(local http-mod (require :ezu.http))
(local {: field-prefixes : options : option-by-name} (require :ezu.cli.args))
(local {: load-config
        : check-config
        : load-schema-cached
        : find-profile
        : merge-ssl
        : discovered-schema} (require :ezu.cli.settings))

;; ---- options and completion ----
(fn shown [o]
  "How usage displays an option."
  (or o.shown (let [name (. o.names 1)]
                (match o.value
                  nil name
                  :number (.. name "=N")
                  :body (.. name "=JSON")
                  :inputs (.. name "=JSON")
                  _ (.. name "=" (or o.arg "VALUE"))))))

(fn completion [o]
  "What flag completion offers for an option, or nil for short-only ones."
  (or o.family (let [long (accumulate [found nil _ n (ipairs o.names)
                                       &until found]
                            (when (n:match "^%-%-") n))]
                 (when long
                   (if o.value (.. long "=") long)))))

(fn applies? [o scope]
  "Whether option o applies to a command of scope, as parsing decides: its
own scope, :any for the API commands op, az and http, or one of its :also."
  (or (= o.scope scope)
      (and (= o.scope :any) (or (= scope :op) (= scope :az) (= scope :http)))
      (accumulate [ok false _ s (ipairs (or o.also [])) &until ok]
        (= s scope))))

(fn scope-options [scope]
  (icollect [_ o (ipairs options)]
    (when (applies? o scope)
      {:shown (shown o) :complete (completion o) :help o.help})))

(fn usage []
  (print "Usage: ezu <command> [args...] [options]")
  (print "")
  (print "Commands:")
  (print "  op  <profile-or-schema> [operation] [path-params...]  Run an API operation")
  (print "  az  <name-or-file> [workflow-id] [path-params...]     Run an Arazzo workflow")
  (print "  http [METHOD] <url-or-path> [--profile NAME]          Send a request without a spec")
  (print "  mcp <profile-or-schema> [--allow-writes]              Serve the operations to AI agents (MCP)")
  (print "  profile <list|show> [name]                            Manage profiles")
  (print "  profile import-restish [FILE] [--dry-run]             Add profiles from a Restish config")
  (print "  auth    <profile> [--logout]                          Authenticate a profile")
  (print "  completion <fish|bash|zsh>                            Print shell completion")
  (print "  --version                                             Print the version")
  (print "  --licenses                                            Print the licenses of the software in the binary")
  (each [_ [title scope] (ipairs [["Options (op):" :op]
                                  ["Options (az):" :az]
                                  ["Options (http):" :http]
                                  ["Options (mcp):" :mcp]])]
    (print "")
    (print title)
    (each [_ o (ipairs (scope-options scope))]
      (print (string.format "  %-21s %s" o.shown o.help))))
  (print "")
  (print (.. "Config: " (util.config-dir) "/config.json")))

(fn sorted-keys [t]
  (doto (icollect [k (pairs (or t {}))]
          k)
    (table.sort)))

(fn op-entries [schema ?source-url ?fetch]
  "Operations of a schema keyed by CLI name, built like a real client;
?source-url locates the documents its refs point to, fetched with ?fetch
options {:ssl :timeout}."
  (let [(ok c) (pcall ezu.client schema
                      {:base-url "http://completion.invalid"
                       :http-fn #nil
                       :source-url ?source-url
                       :ssl (?. ?fetch :ssl)
                       :timeout (?. ?fetch :timeout)})]
    (if ok c {})))

(fn schema-field [schema key]
  "schema[key]; OpenAPI 3.1 schemas may be booleans, which have no fields."
  (when (= (type schema) :table)
    (. schema key)))

(fn enum-of [schema]
  (or (schema-field schema :enum)
      (schema-field (schema-field schema :items) :enum)))

(fn field-entries [prefix kind context]
  "Completion entries for --PREFIX.NAME=VALUE fields: names, or enum values
once a name and = are typed."
  (let [fields (match kind
                 :query (collect [_ p (ipairs (or (?. context :op :parameters)
                                                  []))]
                          (when (= p.in :query)
                            (values p.name
                                    {:enum (enum-of p.schema)
                                     :help p.description})))
                 :header (collect [_ p (ipairs (or (?. context :op :parameters)
                                                   []))]
                           (when (= p.in :header)
                             (values p.name
                                     {:enum (enum-of p.schema)
                                      :help p.description})))
                 :body (collect [name prop (pairs (or (schema-field (?. context
                                                                        :op
                                                                        :body-schema)
                                                                    :properties)
                                                      {}))]
                         (values name
                                 {:enum (enum-of prop)
                                  :help (schema-field prop :description)}))
                 :server (collect [name v (pairs (or (?. context :server
                                                         :variables)
                                                     {}))]
                           (values name {:enum v.enum :help v.description}))
                 _ {})]
    (fn [rest]
      (let [(name) (rest:match "^(.-)=")]
        (if name
            (icollect [_ v (ipairs (or (?. fields name :enum) []))]
              {:value (.. "--" prefix "." name "=" (tostring v))})
            (icollect [_ n (ipairs (sorted-keys fields))]
              {:value (.. "--" prefix "." n "=") :help (. fields n :help)}))))))

(fn split-line [line]
  "(words current positional): the words before the cursor, the word being
typed, and the positional words (values of `--name value` options skipped)."
  (let [words (icollect [w (line:gmatch "%S+")] w)
        current (if (or (= line "") (line:match "%s$")) "" (table.remove words))
        positional []]
    (var skip false)
    (each [_ w (ipairs words)]
      (if skip (set skip false)
          (?. option-by-name w :value) (set skip true)
          (not (w:match "^%-")) (table.insert positional w)))
    (values words current positional)))

(fn home-path [path]
  "path with a leading ~/ expanded, as the shell does for the command itself
but not for the line completion sees."
  (if (path:match "^~/") (.. (or (os.getenv :HOME) "~") (path:sub 2)) path))

(fn completion-context [ctx words positional]
  "What the line refers to: an op schema's operations, server and current
operation, or what the words after an Arazzo document name: the commands of
a group (:entries), or a workflow and its inputs."
  (let [config (or ctx.config {})
        [cmd target name] positional
        c {}]
    (when (and (= cmd :op) target)
      (let [(_ profile) (pcall find-profile config target)
            source (or (?. profile :schema)
                       ;; where discovery found it, for a profile with
                       ;; base-url only
                       (when (and profile ctx.known-schema)
                         (ctx.known-schema profile))
                       (home-path target))
            (ok schema) (pcall ctx.load-schema source profile)]
        (when (and ok (= (type schema) :table))
          (let [index-flag (accumulate [v nil i w (ipairs words)]
                             ;; --server-index=N or --server-index N
                             (or (w:match "^%-%-server%-index=(%d+)$")
                                 (when (= w "--server-index")
                                   (?. words (+ i 1)))
                                 v))
                index (or (tonumber index-flag) (?. profile :server-index) 1)]
            (set c.ops
                 (op-entries schema source
                             {:ssl (merge-ssl profile nil)
                              :timeout ctx.timeout}))
            (set c.server (. (ezu.servers schema) index))
            (set c.op (when name (. c.ops name)))))))
    (when (and (= cmd :az) target)
      (let [;; the profile the command line or the document's configuration
            ;; names: its TLS settings reach the documents
            profile-name (or (accumulate [v nil i w (ipairs words)]
                               (or (w:match "^%-%-profile=(.+)$")
                                   (when (= w "--profile") (?. words (+ i 1))) v))
                             (?. config :arazzo target :profile))
            (_ profile) (pcall find-profile config profile-name)
            load-opts {:trust-sources (or (= true
                                             (?. config :arazzo target
                                                 :trust-sources))
                                          (accumulate [found false _ w (ipairs words)]
                                            (or found (= w "--trust-sources"))))
                       :ssl (merge-ssl profile nil)
                       :timeout ctx.timeout}
            (ok doc) (pcall ctx.load-doc
                            (or (?. config :arazzo target :file)
                                (home-path target))
                            {:ssl load-opts.ssl :timeout ctx.timeout})]
        (when (and ok (= (type doc) :table))
          (let [after (icollect [i w (ipairs positional)]
                        (when (> i 2) w))
                load (arazzo.source-loader load-opts ctx.load-doc)
                (resolved r) (pcall commands.resolve doc after load)]
            (when resolved
              (match r.kind
                :workflow (do
                            (set c.doc r.doc)
                            (set c.workflow r.workflow)
                            (set c.inputs
                                 (arazzo.workflow-inputs r.doc r.workflow)))
                :group (let [(listed entries) (pcall commands.entries r.node
                                                     load)]
                         (when listed
                           (set c.entries entries)))))))))
    c))

(fn positional-entries [config positional context]
  (let [[cmd target] positional
        n (length positional)
        profiles (icollect [_ p (ipairs (sorted-keys config.profiles))]
                   {:value p})]
    (if (= nil cmd) (icollect [_ c (ipairs [:auth
                                            :az
                                            :completion
                                            :http
                                            :mcp
                                            :op
                                            :profile])]
                      {:value c})
        (and (or (= cmd :op) (= cmd :auth) (= cmd :mcp)) (= n 1)) profiles
        (and (= cmd :http) (= n 1))
        (icollect [_ m (ipairs [:DELETE :GET :HEAD :OPTIONS :PATCH :POST :PUT])]
          {:value m}) (and (= cmd :profile) (= n 1))
        [{:value :import-restish} {:value :list} {:value :show}]
        (and (= cmd :profile) (= n 2) (= target :show)) profiles
        (and (= cmd :completion) (= n 1))
        [{:value :bash} {:value :fish} {:value :zsh}] (and (= cmd :op) (= n 2))
        (icollect [_ op-name (ipairs (sorted-keys context.ops))]
          {:value op-name :help (?. context.ops op-name :summary)})
        (and (= cmd :az) (= n 1)) (icollect [_ a (ipairs (sorted-keys config.arazzo))]
                                   {:value a})
        (and (= cmd :az) (>= n 2))
        (icollect [_ e (ipairs (or context.entries []))]
          {:value e.word :help e.summary}) [])))

(fn input-entries [context positional current]
  "Workflow inputs as name= (those not given yet), or the values of the one
being typed (name=…)."
  (let [props (or (schema-field (?. context :inputs) :properties) {})
        name (current:match "^([%a_][%w_%-]*)=")]
    (if name
        (icollect [_ v (ipairs (or (enum-of (. props name)) []))]
          {:value (.. name "=" (tostring v))})
        (let [given (collect [_ w (ipairs positional)]
                      (let [n (w:match "^([%a_][%w_%-]*)[%.=]")]
                        (when n (values n true))))]
          (icollect [_ n (ipairs (sorted-keys props))]
            ;; a list can take more items
            (when (or (not (. given n))
                      (= (schema-field (. props n) :type) :array))
              {:value (.. n "=") :help (schema-field (. props n) :description)}))))))

(fn complete-entries [line ctx]
  "Completion candidates {:value :help} for a command line typed up to the cursor."
  (let [(words current positional) (split-line line)
        cmd (. positional 1)
        context (completion-context ctx words positional)
        (prefix rest) (current:match "^%-%-(%a+)%.(.*)$")
        entries (if prefix
                    (let [kind (. field-prefixes prefix)]
                      (if kind ((field-entries prefix kind context) rest) []))
                    (current:match "^%-")
                    (let [scope (match cmd
                                  :op :op
                                  :az :az
                                  :arazzo :az
                                  :http :http
                                  :mcp :mcp
                                  :auth :auth
                                  :profile :profile
                                  _ :none)
                          offered (icollect [_ o (ipairs (scope-options scope))]
                                    (when o.complete
                                      {:value o.complete :help o.help}))]
                      ;; the one profile subcommand that takes --dry-run
                      (when (and (= cmd :profile)
                                 (= (. positional 2) :import-restish))
                        (each [_ o (ipairs options)]
                          (when (= (?. o :names 1) "--dry-run")
                            (table.insert offered
                                          {:value "--dry-run" :help o.help}))))
                      offered)
                    (and (= cmd :az) context.workflow)
                    (input-entries context positional current)
                    (positional-entries (or ctx.config {}) positional context))
        matching (icollect [_ e (ipairs entries)]
                   (when (= current (e.value:sub 1 (length current)))
                     e))]
    (table.sort matching #(< $1.value $2.value))
    matching))

(fn complete-line [line ctx]
  "Completion candidates for a command line typed up to the cursor."
  (icollect [_ e (ipairs (complete-entries line ctx))]
    e.value))

(fn named-printer [?command]
  "print, with ezu's name replaced by ?command: the completion of a link to
ezu named after a workflow document calls it by that name, through shell
functions of its own (_ezu… become _NAME…), so it can be loaded along ezu's."
  (let [identifier (when ?command
                     (pick-values 1 (?command:gsub "[^%w_]" "_")))]
    (fn [line]
      (print (if ?command
                 (let [(named) (line:gsub "_ezu%f[^%w]" (.. "_" identifier))
                       (called) (named:gsub "%f[%w_]ezu%f[^%w_]" ?command)]
                   called)
                 line)))))

(fn completion-fish [?command]
  (local print (named-printer ?command))
  (print "# ezu fish completion — source this or put in ~/.config/fish/completions/ezu.fish")
  (print "complete -c ezu -f -a '(ezu __complete --describe (commandline -cp))'"))

(fn completion-bash [?command]
  (local print (named-printer ?command))
  (print "# ezu bash completion — add to ~/.bashrc: eval \"$(ezu completion bash)\"")
  (print "_ezu_complete() {")
  (print "  local line=\"${COMP_LINE:0:COMP_POINT}\"")
  ;; the word being completed, from the line: bash 3.2 and later versions
  ;; split COMP_WORDS differently
  (print "  local word=\"${line##* }\"")
  ;; readline replaces only what follows the word's last = or : (word break
  ;; characters): replies leave that part out
  (print "  local prefix=\"${word%\"${word##*[=:]}\"}\"")
  ;; candidates come from the spec: read them as data, one per line, and
  ;; never pass them to compgen -W, which would expand $(...) in them
  (print "  local c q cands=()")
  (print "  while IFS= read -r c; do cands+=(\"$c\"); done < <(ezu __complete \"$line\" 2>/dev/null)")
  (print "  COMPREPLY=()")
  (print "  for c in \"${cands[@]}\"; do")
  ;; bash inserts replies as they are: quote them, so that spaces and shell
  ;; syntax in spec values stay part of one argument; the word may already
  ;; be typed quoted
  ;; a candidate equal to the word up to its = leaves nothing to insert
  (print "    [[ -z \"${c:${#prefix}}\" ]] && continue")
  (print "    if [[ \"$c\" == \"$word\"* ]]; then")
  (print "      printf -v q '%q' \"${c:${#prefix}}\"")
  (print "    else")
  (print "      printf -v q '%q' \"$c\"")
  (print "      [[ \"$q\" == \"$word\"* ]] || continue")
  (print "      q=\"${q:${#prefix}}\"")
  (print "    fi")
  ;; nospace for all (bash 3.2 has no compopt): a complete word gets its
  ;; space here, a name waiting for =VALUE or .FIELD doesn't
  (print "    [[ \"$q\" != *[=.] ]] && q=\"$q \"")
  (print "    COMPREPLY+=(\"$q\")")
  (print "  done")
  (print "}")
  (print "complete -o nospace -F _ezu_complete ezu"))

(fn completion-zsh [?command]
  (local print (named-printer ?command))
  (print "#compdef ezu")
  (print "# ezu zsh completion — add to fpath or source directly")
  (print "_ezu() {")
  (print "  local -a cands")
  ;; the words of this command only (the line may hold several), up to the
  ;; cursor
  (print "  local line=\"${(j: :)${(@)words[1,CURRENT-1]}} $PREFIX\"")
  (print "  cands=(${(f)\"$(ezu __complete \"$line\" 2>/dev/null)\"})")
  (print "  local -a open closed")
  (print "  local c")
  (print "  # no trailing space after NAME= and prefix. so the value can follow")
  (print "  for c in $cands; do")
  (print "    if [[ $c == *[=.] ]]; then open+=($c); else closed+=($c); fi")
  (print "  done")
  (print "  compadd -S '' -- ${open[@]}")
  (print "  compadd -- ${closed[@]}")
  (print "}")
  ;; autoloaded from fpath, the file is _ezu's body: complete now;
  ;; sourced, register the function
  (print "if [[ ${zsh_eval_context[-1]} == loadautofunc ]]; then")
  (print "  _ezu \"$@\"")
  (print "else")
  (print "  compdef _ezu ezu")
  (print "fi"))

(fn command-args [line]
  "What follows the program name in a shell line, which may start with
variable assignments (FOO=1 ezu op ...)."
  (var rest line)
  (var assignment (rest:match "^%s*[%a_][%w_]*=%S*%s+()"))
  (while assignment
    (set rest (rest:sub assignment))
    (set assignment (rest:match "^%s*[%a_][%w_]*=%S*%s+()")))
  (rest:match "^%s*%S+%s+(.*)$"))

(fn run-complete [args ?config]
  "Hidden backend for the shell completion scripts:
ezu __complete [--describe] LINE-UP-TO-CURSOR. ?config: the configuration,
else the one on disk."
  (let [;; a fetch must not keep Tab waiting long
        timeout 5
        describe? (= (. args 2) "--describe")
        line (command-args (or (. args (if describe? 3 2)) ""))
        ctx {:config (or ?config
                         (let [(ok cfg) (pcall #(check-config (load-config)))]
                           (if ok cfg {})))
             ;; the cache as op uses it
             :load-schema (fn [src ?profile]
                            (if (src:match "^https?://")
                                (load-schema-cached src
                                                    {:transport http-mod.request
                                                     :ttl (or (?. ?profile
                                                                  :cache-ttl)
                                                              3600)
                                                     :ssl (merge-ssl ?profile
                                                                     nil)
                                                     :timeout timeout})
                                (ezu.load-schema src)))
             ;; no probing on Tab: what an earlier run found
             :known-schema #(when $.base-url
                              (discovered-schema $.base-url
                                                 (or $.cache-ttl 3600)))
             :load-doc arazzo.load-doc
             : timeout}]
    (each [_ e (ipairs (if line (complete-entries line ctx) []))]
      (print (util.printable (if (and describe? e.help)
                                 (.. e.value "\t"
                                     (: (tostring e.help) :gsub "%s+" " "))
                                 e.value))))))

{: options
 : scope-options
 : usage
 : sorted-keys
 : op-entries
 : enum-of
 : field-entries
 : complete-entries
 : complete-line
 : completion-fish
 : completion-bash
 : completion-zsh
 : run-complete}
