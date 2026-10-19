;; ABOUTME: Secret values in the configuration: written as they are, or read from
;; ABOUTME: the environment, a private file or a command's output, once per run.
(local util (require :ezu.util))
(local trusted-file (require :ezu.trusted-file))

(local kinds {:env true :file true :cmd true})

(fn source-kind [v]
  "The kind of source v is (:env :file :cmd), or nil for a plain value. A
string env:NAME is an env source too."
  (if (and (= (type v) :string) (v:match "^env:.")) :env (= (type v) :table)
      (let [(k) (next v)]
        (when (and k (= nil (next v k)) (. kinds k))
          k))))

(fn source? [v]
  (not= nil (source-kind v)))

(fn problem [v]
  "What is wrong with v as a value or a source, or nil."
  (let [kind (source-kind v)]
    (if (= (type v) :string) nil (= kind :cmd)
        (when (not (and (= (type v.cmd) :table) (. v.cmd 1)
                        (accumulate [ok true _ a (ipairs v.cmd) &until (not ok)]
                          (= (type a) :string))))
          "cmd must be a non-empty list of strings")
        (or (= kind :env) (= kind :file))
        (when (not= (type (. v kind)) :string)
          (.. kind " must be a string"))
        "must be a string, or one of {\"env\": NAME}, {\"file\": PATH}, {\"cmd\": [COMMAND, ARG…]}")))

;; what files and commands gave, by source: read once per run
(local read {})

(fn without-last-newline [text]
  (pick-values 1 (text:gsub "\r?\n$" "")))

(fn from-file [path what]
  (let [file (util.expand-home path)]
    (let [(ok err) (pcall trusted-file.check file "secret file" true)]
      (when (not ok)
        (error (.. what ": " (tostring err)) 0)))
    (let [f (io.open file :rb)]
      (when (not f)
        (error (.. what ": secret file " file " can't be read") 0))
      (let [text (f:read :*a)]
        (f:close)
        (without-last-newline text)))))

(fn from-command [argv what]
  (let [h (io.popen (table.concat (icollect [_ a (ipairs argv)]
                                    (util.shell-quote a))
                                  " "))
        out (h:read :*a)
        (_ how code) (h:close)]
    (when (not (and (= how :exit) (= code 0)))
      (error (.. what ": command " (. argv 1) " failed (" (tostring how) " "
                 (tostring code) ")") 0))
    (without-last-newline out)))

(fn resolve [v what]
  "The value v stands for: v itself, or what its source gives. what names it
in errors (params.secret, say), which never show a value."
  (match (source-kind v)
    :env (let [name (if (= (type v) :string) (v:match "^env:(.+)$") v.env)]
           (or (os.getenv name) (error (.. what ": environment variable " name
                                           " is not set")
                                       0)))
    :file (let [key (.. "file\0" v.file)]
            (when (= nil (. read key))
              (tset read key (from-file v.file what)))
            (. read key))
    :cmd (let [key (.. "cmd\0" (table.concat v.cmd "\0"))]
           (when (= nil (. read key))
             (tset read key (from-command v.cmd what)))
           (. read key))
    _ v))

{: source? : resolve : problem}
