;; ABOUTME: Specs for shared helpers in ezu.util.
;; ABOUTME: Run with `make test` (busted, Fennel loader).
(local util (require :ezu.util))

(describe "origin"
          (fn []
            (it "ends the host where the transport does"
                (fn []
                  ;; the authority ends at the first / ? # (and \, which
                  ;; parsers disagree about), so these go to evil.com
                  (assert.are.equal "https://evil.com:443"
                                    (util.origin "https://evil.com?@api.good.com/"))
                  (assert.are.equal "https://evil.com:443"
                                    (util.origin "https://evil.com#@api.good.com/x"))
                  ;; parsers disagree about \ (libcurl reads it as user info):
                  ;; such a URL has no origin, so it never matches one
                  (assert.is_nil (util.origin "https://evil.com\\@api.good.com/"))
                  (assert.is_nil (util.origin "http://127.0.0.1:9001\\@127.0.0.1:9002/"))))
            (it "gives no origin to a URL holding control characters"
                (fn []
                  (assert.is_nil (util.origin "http://localhost:1\0@127.0.0.1:2/r.json"))
                  (assert.is_nil (util.origin "http://a.test\t/x"))))
            (it "drops user info, lowercases, and makes the port explicit"
                (fn []
                  (assert.are.equal "https://api.good.com:443"
                                    (util.origin "HTTPS://me:pw@API.Good.com/x?y=1"))
                  (assert.are.equal "http://h:8080"
                                    (util.origin "http://a@b@h:8080/"))
                  (assert.are.equal "http://[::1]:80"
                                    (util.origin "http://[::1]/x"))))
            (it "is nil for what is not an absolute http(s) URL"
                (fn []
                  (assert.is_nil (util.origin "/relative"))
                  (assert.is_nil (util.origin "ftp://h/"))
                  (assert.is_nil (util.origin "https:///nohost"))))))

(describe "redact-url"
          (fn []
            (it "masks credentials in the user info and the query"
                (fn []
                  (assert.are.equal "https://<redacted>@h/x?api_key=<redacted>&page=2"
                                    (util.redact-url "https://me:pw@h/x?api_key=s&page=2"))))
            (it "masks all the user info, up to its last @"
                (fn []
                  (assert.are.equal "http://<redacted>@127.0.0.1:1/x"
                                    (util.redact-url "http://a@b:secret@127.0.0.1:1/x"))))
            (it "masks query parameters named as sensitive"
                (fn []
                  (assert.are.equal "https://h/x?appid=<redacted>&page=2"
                                    (util.redact-url "https://h/x?appid=s&page=2"
                                                     ["AppId"]))))))

(describe "resolve-path"
          (fn []
            (it "writes array and object values in the simple style"
                (fn []
                  (assert.are.equal "/p/1,2"
                                    (util.resolve-path "/p/{ids}" {:ids [1 2]}))
                  (assert.are.equal "/p/a,1,b,x%20y"
                                    (util.resolve-path "/p/{o}"
                                                       {:o {:a 1 :b "x y"}}))))
            (it "encodes values that would be dot segments"
                (fn []
                  (assert.are.equal "/p/%2E%2E/x"
                                    (util.resolve-path "/p/{id}/x" {:id ".."}))
                  (assert.are.equal "/p/%2E"
                                    (util.resolve-path "/p/{id}" {:id "."}))
                  (assert.are.equal "/p/a.b"
                                    (util.resolve-path "/p/{id}" {:id "a.b"}))))))

(describe "query-string"
          (fn []
            (it "writes each parameter in its OpenAPI style"
                (fn []
                  (let [qs #(util.query-string $1 $2)]
                    ;; form, exploded: the default
                    (assert.are.equal "a=1&a=2&b=x" (qs {:a [1 2] :b "x"}))
                    (assert.are.equal "x=1&y=2" (qs {:o {:x 1 :y 2}}))
                    ;; form, not exploded
                    (assert.are.equal "a=1,2&o=x,1,y,2"
                                      (qs {:a [1 2] :o {:x 1 :y 2}}
                                          {:a {:explode false}
                                           :o {:explode false}}))
                    (assert.are.equal "a=1%202"
                                      (qs {:a [1 2]}
                                          {:a {:style "spaceDelimited"}}))
                    (assert.are.equal "a=1|2"
                                      (qs {:a [1 2]}
                                          {:a {:style "pipeDelimited"}}))
                    (assert.are.equal "c=G|200|R|100"
                                      (qs {:c {:R 100 :G 200}}
                                          {:c {:style "pipeDelimited"
                                               :explode false}}))
                    (assert.are.equal "c=G%20200%20R%20100"
                                      (qs {:c {:R 100 :G 200}}
                                          {:c {:style "spaceDelimited"
                                               :explode false}}))
                    (assert.are.equal "f[x]=1&f[y]=a%20b"
                                      (qs {:f {:x 1 :y "a b"}}
                                          {:f {:style "deepObject"}}))
                    ;; values are encoded, delimiters are not
                    (assert.are.equal "a=x%2Cy,z"
                                      (qs {:a ["x,y" "z"]}
                                          {:a {:explode false}})))))))

(describe "operation-name"
          (fn []
            (it "turns any operationId into a lowercase dash-separated name"
                (fn []
                  (each [id expected (pairs {"getPetById" "get-pet-by-id"
                                             "GetAccounts" "get-accounts"
                                             "projects/update-item-for-org" "projects-update-item-for-org"
                                             "get_folders_id#get_shared_link" "get-folders-id-get-shared-link"
                                             "post_metadata_taxonomies_id_id_levels:trim" "post-metadata-taxonomies-id-id-levels-trim"
                                             "bookmarks-(-deprecated)-get" "bookmarks-deprecated-get"
                                             "__private.op__" "private-op"
                                             "list-pets" "list-pets"})]
                    (assert.are.equal expected
                                      (util.operation-name "get" "/x"
                                                           {:operationId id})))))
            (it "names operations without an id after method and path"
                (fn []
                  (assert.are.equal "get-pets-pet-id-toys"
                                    (util.operation-name "GET"
                                                         "/pets/{petId}/toys" {}))))))

(describe "camel->kebab"
          (fn []
            (it "simple camelCase"
                (fn []
                  (assert.are.equal "get-pet" (util.camel->kebab "getPet"))))
            (it "multi-word"
                (fn []
                  (assert.are.equal "get-pet-by-id"
                                    (util.camel->kebab "getPetById"))))
            (it "consecutive caps"
                (fn []
                  (assert.are.equal "get-api-key"
                                    (util.camel->kebab "getAPIKey"))))
            (it "leading uppercase run"
                (fn []
                  (assert.are.equal "http-request"
                                    (util.camel->kebab "HTTPRequest"))))
            (it "acronym before word"
                (fn []
                  (assert.are.equal "get-https-url"
                                    (util.camel->kebab "getHTTPSUrl"))))
            (it "all lowercase passthrough"
                (fn []
                  (assert.are.equal "listpets" (util.camel->kebab "listpets"))))))

(describe "extract-path-params"
          (fn []
            (it "extracts single param"
                (fn []
                  (assert.are.same ["petId"]
                                   (util.extract-path-params "/pet/{petId}"))))
            (it "extracts multiple params"
                (fn []
                  (assert.are.same ["userId" "postId"]
                                   (util.extract-path-params "/users/{userId}/posts/{postId}"))))
            (it "returns empty for no params"
                (fn [] (assert.are.same [] (util.extract-path-params "/pets"))))))

(describe "resolve-path"
          (fn []
            (it "substitutes a single param"
                (fn []
                  (let [result (util.resolve-path "/pet/{petId}" {:petId 42})]
                    (assert.are.equal "/pet/42" result))))
            (it "substitutes multiple params"
                (fn []
                  (let [result (util.resolve-path "/users/{userId}/posts/{postId}"
                                                  {:postId 99 :userId 1})]
                    (assert.are.equal "/users/1/posts/99" result))))
            (it "coerces numbers to strings"
                (fn []
                  (let [result (util.resolve-path "/items/{id}" {:id 7})]
                    (assert.are.equal "/items/7" result))))
            (it "errors on missing param"
                (fn []
                  (assert.has.error (fn []
                                      (util.resolve-path "/pet/{petId}" {})))
                  (assert.has.error (fn []
                                      (util.resolve-path "/a/{x}/b/{y}" {:x 1})))))
            (it "percent-encodes reserved characters in values"
                (fn []
                  (assert.are.equal "/items/a%2Fb%3Fc%20d"
                                    (util.resolve-path "/items/{id}"
                                                       {:id "a/b?c d"}))))))

(describe "url-encode"
          (fn []
            (it "keeps unreserved characters"
                (fn []
                  (assert.are.equal "aZ09-._~" (util.url-encode "aZ09-._~"))))
            (it "encodes everything else"
                (fn []
                  (assert.are.equal "%2F%3F%26%3D%20%25"
                                    (util.url-encode "/?&= %"))))))

(describe "url-decode"
          (fn []
            (it "decodes percent escapes and plus signs"
                (fn []
                  (assert.are.equal "4/0Ab c" (util.url-decode "4%2F0Ab+c"))))))

(describe "form-encode"
          (fn []
            (it "encodes pairs in sorted key order"
                (fn []
                  (assert.are.equal "a=1&b=x%20y"
                                    (util.form-encode {:b "x y" :a 1}))))
            (it "repeats key for array values"
                (fn []
                  (assert.are.equal "id=1&id=2" (util.form-encode {:id [1 2]}))))
            (it "returns empty string for empty table"
                (fn []
                  (assert.are.equal "" (util.form-encode {}))))))

(describe "resolve-reference"
          (fn []
            (it "keeps absolute URLs"
                (fn []
                  (assert.are.equal "https://x/y.json"
                                    (util.resolve-reference "dir/a.yaml"
                                                            "https://x/y.json"))))
            (it "keeps absolute paths"
                (fn []
                  (assert.are.equal "/etc/a.json"
                                    (util.resolve-reference "dir/a.yaml"
                                                            "/etc/a.json"))))
            (it "resolves relative to a file's directory"
                (fn []
                  (assert.are.equal "dir/specs/api.json"
                                    (util.resolve-reference "dir/a.yaml"
                                                            "./specs/api.json"))))
            (it "resolves relative to a file in the current directory"
                (fn []
                  (assert.are.equal "api.json"
                                    (util.resolve-reference "a.yaml" "api.json"))))
            (it "resolves relative to a URL"
                (fn []
                  (assert.are.equal "https://h/p/api.json"
                                    (util.resolve-reference "https://h/p/a.yaml"
                                                            "./api.json"))))
            (it "resolves parent segments"
                (fn []
                  (assert.are.equal "https://h/api.json"
                                    (util.resolve-reference "https://h/p/a.yaml"
                                                            "../api.json"))))))

(describe "append-query"
          (fn []
            (it "returns url unchanged without params"
                (fn []
                  (assert.are.equal "https://h/p"
                                    (util.append-query "https://h/p" {}))))
            (it "adds a query string"
                (fn []
                  (assert.are.equal "https://h/p?a=1"
                                    (util.append-query "https://h/p" {:a 1}))))
            (it "extends an existing query string"
                (fn []
                  (assert.are.equal "https://h/p?x=0&a=1"
                                    (util.append-query "https://h/p?x=0" {:a 1}))))))

(fn eval-with-env [env code]
  (let [h (io.popen (.. env " lua -e "
                        (string.format "%q"
                                       (.. "package.path='./lua/?.lua;'..package.path "
                                           code))))
        out (h:read "*a")]
    (h:close)
    (out:match "^%s*(.-)%s*$")))

(describe "ezu directories"
          (fn []
            (it "honors XDG_CACHE_HOME and XDG_CONFIG_HOME"
                (fn []
                  (assert.are.equal "/x/c/ezu"
                                    (eval-with-env "XDG_CACHE_HOME=/x/c"
                                                   "print(require('ezu.util')['cache-dir']())"))
                  (assert.are.equal "/x/k/ezu"
                                    (eval-with-env "XDG_CONFIG_HOME=/x/k"
                                                   "print(require('ezu.util')['config-dir']())"))))
            (it "defaults to ~/.cache and ~/.config"
                (fn []
                  (assert.are.equal "/h/.cache/ezu"
                                    (eval-with-env "env -u XDG_CACHE_HOME HOME=/h"
                                                   "print(require('ezu.util')['cache-dir']())"))
                  (assert.are.equal "/h/.config/ezu"
                                    (eval-with-env "env -u XDG_CONFIG_HOME HOME=/h"
                                                   "print(require('ezu.util')['config-dir']())"))))))

(describe "resolve-reference URL edge cases"
          (fn []
            (it "resolves root-relative refs against a URL origin"
                (fn []
                  (assert.are.equal "https://ex.com/openapi.yaml"
                                    (util.resolve-reference "https://ex.com/specs/a.yaml"
                                                            "/openapi.yaml"))))
            (it "adds the separator for a base URL without path"
                (fn []
                  (assert.are.equal "https://ex.com/openapi.yaml"
                                    (util.resolve-reference "https://ex.com"
                                                            "openapi.yaml"))))
            (it "does not climb above the URL root"
                (fn []
                  (assert.are.equal "https://ex.com/x.yaml"
                                    (util.resolve-reference "https://ex.com/a.yaml"
                                                            "../x.yaml"))))
            (it "ignores the query string of the base"
                (fn []
                  (assert.are.equal "https://ex.com/o.yaml"
                                    (util.resolve-reference "https://ex.com/a.yaml?x=1/2"
                                                            "o.yaml"))))))

(describe "secrets"
          (fn []
            (it "recognizes credential-like names"
                (fn []
                  (each [_ n (ipairs ["api_key"
                                      "X-API-Key"
                                      "access_token"
                                      "client_secret"
                                      "sig"
                                      "signature"
                                      "password"
                                      "cookie"])]
                    (assert.is_true (util.secret-name? n)))
                  (assert.is_false (util.secret-name? "page"))))
            (it "redacts secret query parameters in URLs"
                (fn []
                  (assert.are.equal "https://h/x?api_key=<redacted>&page=2"
                                    (util.redact-url "https://h/x?api_key=SECRET&page=2"))))))

(describe "json-pointer"
          (fn []
            (it "returns the whole value for an empty pointer"
                (fn []
                  (assert.are.same {:a 1} (util.json-pointer {:a 1} ""))))
            (it "decodes ~1 before ~0"
                (fn []
                  (assert.are.equal 1
                                    (util.json-pointer {"a/b" {"~1" 1}}
                                                       "/a~1b/~01"))))
            (it "indexes arrays 0-based but prefers a matching string key"
                (fn []
                  (assert.are.equal "b"
                                    (util.json-pointer {:x ["a" "b"]} "/x/1"))
                  (assert.are.equal "s" (util.json-pointer {"1" "s"} "/1"))))
            (it "returns nil for missing paths"
                (fn []
                  (assert.is_nil (util.json-pointer {:a 1} "/a/b"))))))

(describe "form-encode objects"
          (fn []
            (it "rejects object values instead of dropping them"
                (fn []
                  (let [(ok err) (pcall util.form-encode {:filter {:x 1}})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find
                                         "'filter' is an object" 1 true)))))))

(fn mode-of [path]
  "path's mode as ls shows it, without macOS's @ for extended attributes,
which grant no access; a + for an access list stays."
  (let [p (io.popen (.. "ls -ld " (util.shell-quote path)))
        out (p:read :*a)]
    (p:close)
    (out:match "^([^%s@]+)")))

(describe "write-private"
          (fn []
            (it "writes a file only its owner can read, in a private directory"
                (fn []
                  (let [base (os.tmpname)
                        dir (.. base "-d")
                        path (.. dir "/f.json")]
                    (assert.is_true (util.write-private path "secret"))
                    (assert.are.equal "-rw-------" (mode-of path))
                    (assert.are.equal "drwx------" (mode-of dir))
                    (with-open [f (io.open path)]
                      (assert.are.equal "secret" (f:read :*a)))
                    (os.remove path)
                    (os.remove dir)
                    (os.remove base))))
            (it "makes an existing file private"
                (fn []
                  (let [path (os.tmpname)]
                    (os.execute (.. "chmod 644 " path))
                    (assert.is_true (util.write-private path "x"))
                    (assert.are.equal "-rw-------" (mode-of path))
                    (os.remove path))))))

(describe "printable"
          (fn []
            (it "escapes control characters but newlines and tabs"
                (fn []
                  (assert.are.equal "a\\x1B[31mb\\x1B]52;c;x\\x07\nc\td"
                                    (util.printable "a\27[31mb\27]52;c;x\7\nc\td"))))))

(describe "resolve-reference"
          (fn []
            (it "keeps trailing slashes and empty segments"
                (fn []
                  (assert.are.equal "https://api.example.com/api/items/?page=2"
                                    (util.resolve-reference "https://api.example.com/v1/spec.json"
                                                            "/api/items/?page=2"))
                  (assert.are.equal "https://h/v1//x"
                                    (util.resolve-reference "https://h/v1/spec.json"
                                                            "/v1//x"))
                  (assert.are.equal "https://h/a/"
                                    (util.resolve-reference "https://h/a/b/c"
                                                            ".."))
                  (assert.are.equal "https://h/x"
                                    (util.resolve-reference "https://h/a"
                                                            "/../x"))))
            (it "leaves the query and fragment as they are"
                (fn []
                  (assert.are.equal "https://api.example.com/v1/items?cursor=ab//cd=="
                                    (util.resolve-reference "https://api.example.com/v1/items?page=1"
                                                            "/v1/items?cursor=ab//cd=="))
                  (assert.are.equal "https://api.example.com/v1/items?cursor=a/./b#x/../y"
                                    (util.resolve-reference "https://api.example.com/v1/items"
                                                            "items?cursor=a/./b#x/../y"))))
            (it "takes network-path references to another host"
                (fn []
                  (assert.are.equal "https://cdn.example.org/shared/pet.json"
                                    (util.resolve-reference "https://specs.example.com/v1/openapi.json"
                                                            "//cdn.example.org/shared/pet.json"))))))

(describe "nested values in URLs and forms"
          (fn []
            (it "are errors rather than table addresses"
                (fn []
                  (each [_ f (ipairs [#(util.form-encode {:items [{:price "p1"}]})
                                      #(util.query-string {:filter {:a {:b 1}}}
                                                          {:filter {:style "deepObject"
                                                                    :explode true}})
                                      #(util.query-string {:ids [{:x 1}]})
                                      #(util.resolve-path "/x/{id}"
                                                          {:id {:a {:b 1}}})])]
                    (let [(ok err) (pcall f)]
                      (assert.is_false ok)
                      (assert.is_truthy (: (tostring err) :find
                                           "nested objects and arrays can't be sent"
                                           1 true))))))))

(describe "printable and other controls"
          (fn []
            (it "escapes C1 controls and bidirectional overrides"
                (fn []
                  (assert.are.equal "a\\u{202E}b\\u{009B}c\\u{2066}d é"
                                    (util.printable "a\u{202E}b\u{9B}c\u{2066}d é"))))))
