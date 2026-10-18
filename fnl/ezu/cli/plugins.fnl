;; ABOUTME: Plugins: Lua or Fennel files listed in the config, loaded when a
;; ABOUTME: profile uses what they provide; for now, functions signing requests.
(local util (require :ezu.util))
(local auth (require :ezu.auth))

(fn fail [path why]
  (error (.. "plugin " path ": " why) 0))

(fn expand-home [path]
  (if (path:match "^~/")
      (.. (or (os.getenv :HOME) "~") (path:sub 2))
      path))

(fn command-output [command]
  (let [h (io.popen command)
        out (when h (h:read :*a))]
    (when h (h:close))
    (or out "")))

(var user-id nil)

(fn listing [path]
  "(mode owner target) of path as ls -ldn shows it, target for a link."
  (let [out (command-output (.. "ls -ldn " (util.shell-quote path)
                                " 2>/dev/null"))
        (mode owner) (out:match "^(%S+)%s+%S+%s+(%d+)")]
    (values mode owner (out:match " %-> (.-)%s*$"))))

(fn dirname [path]
  (or (path:match "^(.*)/[^/]*$") "."))

(fn real-file [path]
  "path with the links leading to it followed."
  (var current path)
  (for [_ 1 16 &until (not= "l" (: (or (listing current) "") :sub 1 1))]
    (let [(_ _ target) (listing current)]
      (set current (if (target:match "^/") target
                       (.. (dirname current) "/" target)))))
  current)

(fn access-list? [path mode]
  "Whether path has an access list. ls marks one with + after the mode; on
macOS, extended attributes take that place (@) and hide it, so the entries
ls -le lists tell."
  (or (= (mode:sub 11 11) "+")
      (and (= (mode:sub 11 11) "@")
           (not= nil (: (command-output (.. "ls -lden " (util.shell-quote path)
                                            " 2>/dev/null"))
                        :match "\n%s*%d+: ")))))

(fn others-can-change? [mode]
  "Whether a file or directory of mode can be changed by group or others:
for a directory, unless it is sticky (others can't replace what is yours)."
  (and (or (= (mode:sub 6 6) :w) (= (mode:sub 9 9) :w))
       (not (and (= (mode:sub 1 1) :d)
                 (or (= (mode:sub 10 10) :t) (= (mode:sub 10 10) :T))))))

(fn check-file [path]
  "Raise unless path is a file of the user's, in directories of the user's or
root's, that no one else can change: a plugin runs with the user's
credentials. Links are followed."
  (when (not user-id)
    (set user-id (: (command-output "id -u") :match "%d+")))
  (let [file (real-file path)
        (mode owner) (listing file)]
    (when (not mode)
      (fail path "not found"))
    (when (not= (mode:sub 1 1) "-")
      (fail path "not a file"))
    (when (not= owner user-id)
      (fail path "belongs to another user"))
    (when (others-can-change? mode)
      (fail path (.. "can be changed by other users, who would get your credentials (chmod go-w "
                     file ")")))
    (when (access-list? file mode)
      (fail path
            "has an access list, which may let other users change it: remove it"))
    ;; nor may anyone else replace it: no directory up to / is theirs to change
    (var dir (: (command-output (.. "cd " (util.shell-quote (dirname file))
                                    " 2>/dev/null && pwd -P"))
                :match "^(.-)%s*$"))
    (while (and dir (not= dir ""))
      (let [(dir-mode dir-owner) (listing dir)]
        (when (or (not dir-mode)
                  (not (or (= dir-owner user-id) (= dir-owner "0")))
                  (others-can-change? dir-mode))
          (fail path
                (.. "is in " dir
                    ", which can be changed by other users, who would get your credentials")))
        (set dir (if (= dir "/") nil
                     (let [parent (dirname dir)]
                       (if (= parent "") "/" parent))))))))

(fn evaluate [path]
  "What the plugin file at path returns, from the text checked."
  (let [f (io.open path :rb)
        text (if f (f:read :*a) (fail path "can't be read"))]
    (f:close)
    (if (path:match "%.fnl$")
        (let [(ok fennel) (pcall require :fennel)]
          (when (not ok)
            (fail path
                  "Fennel plugins need the Fennel compiler: luarocks install fennel"))
          (fennel.eval text {:filename path}))
        (path:match "%.lua$")
        (let [(chunk err) (load text (.. "@" path) :t)]
          (if chunk (chunk) (error err 0)))
        (fail path "must be a .lua or .fnl file"))))

(local loaded {})

(fn load-plugin [path]
  "The table the plugin at path returns, checked; loaded once."
  (or (. loaded path) (do
                        (check-file path)
                        (let [(ok plugin) (pcall evaluate path)]
                          (when (not ok)
                            (fail path (tostring plugin)))
                          (when (not= (type plugin) :table)
                            (fail path
                                  "must return a table, like {:auth {:name function}}"))
                          (when (not (or (= nil plugin.auth)
                                         (= (type plugin.auth) :table)))
                            (fail path "auth must be a table of functions"))
                          (each [name f (pairs (or plugin.auth {}))]
                            (when (not= (type f) :function)
                              (fail path
                                    (.. "auth " (tostring name)
                                        " must be a function")))
                            (when (auth.built-in? name)
                              (fail path (.. "auth " name " is built in"))))
                          (tset loaded path plugin)
                          plugin))))

(fn plugin-paths [config]
  "The config's plugin files, each once; relative paths would depend on the
directory ezu runs in, so they are refused."
  (let [seen {}]
    (icollect [_ p (ipairs (or config.plugins []))]
      (let [path (expand-home p)]
        (when (not (path:match "^/"))
          (error (.. "plugin " p ": must be an absolute path, or start with ~/")
                 0))
        (when (not (. seen path))
          (tset seen path true)
          path)))))

(fn resolve-auth [config auth-config]
  "auth-config as is when ezu knows its name; else a copy with :sign, the
function of the config's plugins that provides it, and :plugin, its file.
Plugins are only loaded for an auth that isn't built in."
  (if (auth.built-in? auth-config.name)
      auth-config
      (let [found (accumulate [found nil _ path (ipairs (plugin-paths config))]
                    (let [f (?. (load-plugin path) :auth auth-config.name)]
                      (when (and f found)
                        (error (.. "auth '" auth-config.name
                                   "' is provided by two plugins: " found.path
                                   " and " path)
                               0))
                      (if f {: f : path} found)))]
        (when (not found)
          (error (.. "auth '" (tostring auth-config.name)
                     "' is not built in, and no plugin provides it")
                 0))
        (doto (collect [k v (pairs auth-config)] k v)
          (tset :sign found.f)
          (tset :plugin found.path)))))

{: resolve-auth}
