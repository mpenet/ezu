;; ABOUTME: Specs for plugins: loading Lua and Fennel files listed in the config,
;; ABOUTME: refusing files others can change, and resolving the auth they provide.
(local plugins (require :ezu.cli.plugins))

(fn plugin-file [extension text ?mode]
  "A plugin file with text, mode ?mode (default 600); returns its path."
  (let [path (.. (os.tmpname) extension)]
    (with-open [f (io.open path :w)]
      (f:write text))
    (os.execute (.. "chmod " (or ?mode "600") " " path))
    path))

(local lua-plugin
       "return {auth = {demo = function(req, params) return {headers = {authorization = 'Demo ' .. params.token .. ' ' .. req.method}} end}}")

(local fennel-plugin
       "{:auth {:fdemo (fn [req params] {:headers {:x-sig (.. params.token \":\" req.url)}})}}")

(describe "plugins"
          (fn []
            (it "gives a profile's auth the signing function a Lua plugin provides"
                (fn []
                  (let [path (plugin-file ".lua" lua-plugin)
                        auth (plugins.resolve-auth {:plugins [path]}
                                                   {:name "demo"
                                                    :params {:token "t1"}})]
                    (os.remove path)
                    (assert.are.equal "Demo t1 GET"
                                      (. (auth.sign {:method "GET"}
                                                    {:token "t1"})
                                         :headers :authorization))
                    (assert.are.equal path auth.plugin))))
            (it "loads plugins written in Fennel"
                (fn []
                  (let [path (plugin-file ".fnl" fennel-plugin)
                        auth (plugins.resolve-auth {:plugins [path]}
                                                   {:name "fdemo"})]
                    (os.remove path)
                    (assert.are.equal "k:https://x.test/"
                                      (. (auth.sign {:url "https://x.test/"}
                                                    {:token "k"})
                                         :headers :x-sig)))))
            (it "leaves built-in auth alone, without loading any plugin"
                (fn []
                  (let [cfg {:name "bearer" :params {:token "t"}}]
                    (assert.are.equal cfg
                                      (plugins.resolve-auth {:plugins ["/nonexistent/p.lua"]}
                                                            cfg)))))
            (it "says when no plugin provides an auth"
                (fn []
                  (let [path (plugin-file ".lua" lua-plugin)
                        (ok err) (pcall plugins.resolve-auth {:plugins [path]}
                                        {:name "nope"})]
                    (os.remove path)
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "auth 'nope' is not built in, and no plugin provides it"
                                         1 true)))))
            (it "refuses a plugin that others can change"
                (fn []
                  (each [_ mode (ipairs ["620" "602"])]
                    (let [path (plugin-file ".lua" lua-plugin mode)
                          (ok err) (pcall plugins.resolve-auth
                                          {:plugins [path]} {:name "demo"})]
                      (os.remove path)
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find
                                           "can be changed by other users" 1
                                           true)
                                        (tostring err))))))
            (it "refuses plugins that don't provide auth functions"
                (fn []
                  (each [_ [extension text why] (ipairs [[".lua"
                                                          "return 42"
                                                          "must return a table"]
                                                         [".lua"
                                                          "return {auth = {demo = 'x'}}"
                                                          "auth demo must be a function"]
                                                         [".lua"
                                                          "error('boom')"
                                                          "boom"]
                                                         [".txt"
                                                          "{}"
                                                          "must be a .lua or .fnl file"]])]
                    (let [path (plugin-file extension text)
                          (ok err) (pcall plugins.resolve-auth
                                          {:plugins [path]} {:name "demo"})]
                      (os.remove path)
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find why 1 true)
                                        (tostring err))))))
            (it "signs Exoscale requests as Exoscale's client does, with the example plugin"
                (fn []
                  (let [digest (require :ezu.digest)
                        auth-mod (require :ezu.auth)
                        path (with-open [f (io.open "doc/examples/plugins/exoscale.fnl")]
                               (plugin-file ".fnl" (f:read :*a)))
                        resolved (plugins.resolve-auth {:plugins [path]}
                                                       {:name "exoscale"
                                                        :params {:key "EXOkey"
                                                                 :secret "s3cret"}})
                        sent []
                        wrapped (auth-mod.wrap-http-fn resolved
                                                       #(do
                                                          (table.insert sent $)
                                                          {:status 200
                                                           :headers {}}))]
                    (os.remove path)
                    (wrapped {:method "GET"
                              :url "https://api.test/v2/template?visibility=public&b=x&b=y"
                              :headers {}})
                    (let [header (. sent 1 :headers :authorization)
                          expires (header:match "expires=(%d+)")
                          message (.. "GET /v2/template\n\npublic\n\n" expires)]
                      (assert.are.equal (.. "EXO2-HMAC-SHA256 credential=EXOkey,signed-query-args=visibility,expires="
                                            expires ",signature="
                                            (digest.base64 (digest.hmac-sha256 "s3cret"
                                                                               message)))
                                        header)))))
            (it "refuses a plugin in a directory others can change"
                (fn []
                  (let [dir (.. (os.tmpname) ".d")]
                    (os.execute (.. "mkdir " dir " && chmod 777 " dir))
                    (let [path (.. dir "/p.lua")]
                      (with-open [f (io.open path :w)]
                        (f:write lua-plugin))
                      (os.execute (.. "chmod 600 " path))
                      (let [(ok err) (pcall plugins.resolve-auth
                                            {:plugins [path]} {:name "demo"})]
                        (os.remove path)
                        (os.remove dir)
                        (assert.is_false ok)
                        (assert.is_truthy (: (tostring err) :find
                                             "can be changed by other users" 1
                                             true)
                                          (tostring err))
                        (assert.is_truthy (: (tostring err) :find dir 1 true)))))))
            (it "refuses a plugin with an access list"
                (fn []
                  (let [path (plugin-file ".lua" lua-plugin)]
                    ;; macOS: grant write through an access list, mode unchanged
                    (if (os.execute (.. "chmod +a 'everyone allow write' " path
                                        " 2>/dev/null"))
                        (let [(ok err) (pcall plugins.resolve-auth
                                              {:plugins [path]} {:name "demo"})]
                          (os.remove path)
                          (assert.is_false ok)
                          (assert.is_truthy (: (tostring err) :find
                                               "access list" 1 true)))
                        (os.remove path)))))
            (it "refuses a plugin in a directory whose access list lets others change it"
                (fn []
                  (let [dir (.. (os.tmpname) ".d")]
                    (os.execute (.. "mkdir " dir " && chmod 700 " dir))
                    (let [path (.. dir "/p.lua")]
                      (with-open [f (io.open path :w)]
                        (f:write lua-plugin))
                      (os.execute (.. "chmod 600 " path))
                      ;; macOS: let everyone replace files in dir, mode unchanged
                      (let [granted (os.execute (.. "chmod +a 'group:everyone allow add_file,delete_child' "
                                                    dir " 2>/dev/null"))
                            (ok err) (pcall plugins.resolve-auth
                                            {:plugins [path]} {:name "demo"})]
                        (os.remove path)
                        (os.remove dir)
                        (when granted
                          (assert.is_false ok)
                          (assert.is_truthy (: (tostring err) :find
                                               "access list" 1 true)
                                            (tostring err))
                          (assert.is_truthy (: (tostring err) :find dir 1 true))))))))
            (it "accepts access lists that only deny"
                (fn []
                  (let [dir (.. (os.tmpname) ".d")]
                    (os.execute (.. "mkdir " dir " && chmod 700 " dir))
                    (let [path (.. dir "/p.lua")]
                      (with-open [f (io.open path :w)]
                        (f:write lua-plugin))
                      (os.execute (.. "chmod 600 " path))
                      ;; macOS home folders carry such an entry
                      (let [granted (and (os.execute (.. "chmod +a 'group:everyone deny delete' "
                                                         dir " 2>/dev/null"))
                                         (os.execute (.. "chmod +a 'group:everyone deny write' "
                                                         path " 2>/dev/null")))
                            (ok err) (pcall plugins.resolve-auth
                                            {:plugins [path]} {:name "demo"})]
                        (os.remove path)
                        (os.remove dir)
                        (when granted
                          (assert.is_true ok (tostring err))))))))
            (it "refuses relative plugin paths"
                (fn []
                  (let [(ok err) (pcall plugins.resolve-auth
                                        {:plugins ["plugins/p.lua"]}
                                        {:name "demo"})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "must be an absolute path, or start with ~/"
                                         1 true)))))
            (it "loads a plugin listed twice once"
                (fn []
                  (let [path (plugin-file ".lua" lua-plugin)
                        (ok auth) (pcall plugins.resolve-auth
                                         {:plugins [path path]} {:name "demo"})]
                    (os.remove path)
                    (assert.is_true ok (tostring auth)))))
            (it "says how to get Fennel when it isn't there"
                (fn []
                  (let [path (plugin-file ".fnl" fennel-plugin)
                        saved (. package.loaded :fennel)]
                    (tset package.loaded :fennel nil)
                    (tset package.preload :fennel
                          #(error "module 'fennel' not found"))
                    (let [(ok err) (pcall plugins.resolve-auth
                                          {:plugins [path]} {:name "fdemo"})]
                      (tset package.preload :fennel nil)
                      (tset package.loaded :fennel saved)
                      (os.remove path)
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find
                                           "luarocks install fennel" 1 true))))))
            (it "refuses two plugins providing the same auth, and built-in names"
                (fn []
                  (let [a (plugin-file ".lua" lua-plugin)
                        b (plugin-file ".lua" lua-plugin)
                        builtin (plugin-file ".lua"
                                             "return {auth = {bearer = function() end}}")
                        (ok1 err1) (pcall plugins.resolve-auth {:plugins [a b]}
                                          {:name "demo"})
                        (ok2 err2) (pcall plugins.resolve-auth
                                          {:plugins [builtin]} {:name "demo"})]
                    (each [_ p (ipairs [a b builtin])]
                      (os.remove p))
                    (assert.is_false ok1)
                    (assert.is_truthy (: (tostring err1) :find
                                         "provided by two plugins" 1 true))
                    (assert.is_false ok2)
                    (assert.is_truthy (: (tostring err2) :find "built in" 1
                                         true)))))))
