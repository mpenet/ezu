;; ABOUTME: Plugins: Lua or Fennel files listed in the config, loaded when a
;; ABOUTME: profile uses what they provide; for now, functions signing requests.
(local util (require :ezu.util))
(local auth (require :ezu.auth))
(local trusted-file (require :ezu.trusted-file))

(fn fail [path why]
  (error (.. "plugin " path ": " why) 0))

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
                        (trusted-file.check path "plugin")
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
      (let [path (util.expand-home p)]
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
