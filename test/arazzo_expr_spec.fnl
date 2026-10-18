;; ABOUTME: Specs for Arazzo runtime expressions, templates and criteria.
;; ABOUTME: Run with `make test` (busted, Fennel loader).
(local expr (require :ezu.arazzo.expr))

(fn ctx []
  {:inputs {:host "api.example.com" :userId "42" :limit 10}
   :response {:status 200
              :headers {:content-type "application/json" :x-trace "abc"}
              :body {:token "tok123"
                     :user {:id 1 :name "Rex"}
                     :items [{:id 1} {:id 2}]}}
   :request {:url "https://api.example.com/users"
             :method "GET"
             :body {:q "search"}}
   :steps {:login {:outputs {:token "bearer-tok" :userId 99}
                   :response {:status 200
                              :headers {}
                              :body {:access_token "at123"}}
                   :request {:body {:username "u"} :headers {}}}
           :getUser {:outputs {:name "Rex"} :response nil :request nil}}
   :workflows {}})

;; ---- json-pointer ----

(describe "json-pointer"
          (fn []
            (it "resolves top-level key"
                (fn []
                  (assert.are.equal "tok123"
                                    (expr.json-pointer {:token "tok123"}
                                                       "/token"))))
            (it "resolves nested key"
                (fn []
                  (assert.are.equal "Rex"
                                    (expr.json-pointer {:user {:name "Rex"}}
                                                       "/user/name"))))
            (it "resolves array index (0-based)"
                (fn []
                  (assert.are.equal 2
                                    (expr.json-pointer [{:id 1} {:id 2}]
                                                       "/1/id"))))
            (it "returns nil for missing key"
                (fn []
                  (assert.is_nil (expr.json-pointer {:a 1} "/b"))))
            (it "handles ~1 as / and ~0 as ~"
                (fn []
                  (assert.are.equal "v" (expr.json-pointer {"a/b" "v"} "/a~1b"))))))

;; ---- eval ----

(describe "expr.eval"
          (fn []
            (it "resolves $inputs.key"
                (fn []
                  (assert.are.equal "42" (expr.eval (ctx) "$inputs.userId"))))
            (it "resolves $statusCode"
                (fn []
                  (assert.are.equal 200 (expr.eval (ctx) "$statusCode"))))
            (it "resolves $url"
                (fn []
                  (assert.are.equal "https://api.example.com/users"
                                    (expr.eval (ctx) "$url"))))
            (it "resolves $response.body#/token"
                (fn []
                  (assert.are.equal "tok123"
                                    (expr.eval (ctx) "$response.body#/token"))))
            (it "resolves $response.body#/user/name"
                (fn []
                  (assert.are.equal "Rex"
                                    (expr.eval (ctx)
                                               "$response.body#/user/name"))))
            (it "resolves $response.header.x-trace"
                (fn []
                  (assert.are.equal "abc"
                                    (expr.eval (ctx) "$response.header.x-trace"))))
            (it "resolves $request.body#/q"
                (fn []
                  (assert.are.equal "search"
                                    (expr.eval (ctx) "$request.body#/q"))))
            (it "resolves $steps.login.outputs.token"
                (fn []
                  (assert.are.equal "bearer-tok"
                                    (expr.eval (ctx)
                                               "$steps.login.outputs.token"))))
            (it "resolves $steps.login.response.body#/access_token"
                (fn []
                  (assert.are.equal "at123"
                                    (expr.eval (ctx)
                                               "$steps.login.response.body#/access_token"))))
            (it "resolves $sourceDescriptions sentinel"
                (fn []
                  (let [v (expr.eval (ctx) "$sourceDescriptions.myapi.getPet")]
                    (assert.are.equal "myapi" v.__source)
                    (assert.are.equal "getPet" v.__operationId))))
            (it "keeps dotted operationIds whole in $sourceDescriptions"
                (fn []
                  (let [v (expr.eval (ctx)
                                     "$sourceDescriptions.gcs.storage.buckets.list")]
                    (assert.are.equal "gcs" v.__source)
                    (assert.are.equal "storage.buckets.list" v.__operationId))))
            (it "returns expr unchanged when not a $ expression"
                (fn []
                  (assert.are.equal "hello" (expr.eval (ctx) "hello"))))
            (it "substitutes {$expr} templates"
                (fn []
                  (let [result (expr.eval (ctx)
                                          "https://{$inputs.host}/users/{$inputs.userId}")]
                    (assert.are.equal "https://api.example.com/users/42" result))))))

;; ---- eval-criterion: simple ----

(describe "eval-criterion simple"
          (fn []
            (it "== true for matching status"
                (fn []
                  (assert.is_true (expr.eval-criterion (ctx)
                                                       {:condition "$statusCode == 200"}))))
            (it "== false for non-matching status"
                (fn []
                  (assert.is_false (expr.eval-criterion (ctx)
                                                        {:condition "$statusCode == 404"}))))
            (it "!= works"
                (fn []
                  (assert.is_true (expr.eval-criterion (ctx)
                                                       {:condition "$statusCode != 404"}))))
            (it ">= works"
                (fn []
                  (assert.is_true (expr.eval-criterion (ctx)
                                                       {:condition "$statusCode >= 200"}))
                  (assert.is_false (expr.eval-criterion (ctx)
                                                        {:condition "$statusCode >= 300"}))))
            (it "&& requires both true"
                (fn []
                  (assert.is_true (expr.eval-criterion (ctx)
                                                       {:condition "$statusCode == 200 && $statusCode != 404"}))
                  (assert.is_false (expr.eval-criterion (ctx)
                                                        {:condition "$statusCode == 200 && $statusCode == 404"}))))
            (it "|| requires at least one true"
                (fn []
                  (assert.is_true (expr.eval-criterion (ctx)
                                                       {:condition "$statusCode == 404 || $statusCode == 200"}))
                  (assert.is_false (expr.eval-criterion (ctx)
                                                        {:condition "$statusCode == 404 || $statusCode == 500"}))))
            (it "string comparison"
                (fn []
                  (assert.is_true (expr.eval-criterion (ctx)
                                                       {:condition "$response.body#/token == \"tok123\""}))))
            (it "missing value is falsy"
                (fn []
                  (assert.is_false (expr.eval-criterion (ctx)
                                                        {:condition "$response.body#/missing == \"x\""})))))
          ;; ---- eval-criterion: regex ----
          (describe "eval-criterion regex"
                    (fn []
                      (it "matches 2xx pattern on status code"
                          (fn []
                            (assert.is_true (expr.eval-criterion (ctx)
                                                                 {:type :regex
                                                                  :context "$statusCode"
                                                                  :condition "^2"}))))
                      (it "fails when no match"
                          (fn []
                            (assert.is_false (expr.eval-criterion (ctx)
                                                                  {:type :regex
                                                                   :context "$statusCode"
                                                                   :condition "^4"}))))))
          (describe "eval-criterion regex syntax"
                    (fn []
                      (it "reads ECMAScript-style patterns, as the spec's examples are"
                          (fn []
                            (assert.is_true (expr.eval-criterion (ctx)
                                                                 {:type :regex
                                                                  :context "$statusCode"
                                                                  :condition "^2\\d{2}$"}))
                            (assert.is_true (expr.eval-criterion (ctx)
                                                                 {:type :regex
                                                                  :context "$statusCode"
                                                                  :condition "^(200|201)$"}))
                            (assert.is_false (expr.eval-criterion (ctx)
                                                                  {:type :regex
                                                                   :context "$statusCode"
                                                                   :condition "^2%d%d$"}))))
                      (it "fails with a problem for a malformed pattern"
                          (fn []
                            (let [(passed problem) (expr.eval-criterion (ctx)
                                                                        {:type :regex
                                                                         :context "$statusCode"
                                                                         :condition "(2"})]
                              (assert.is_false passed)
                              (assert.is_truthy (problem:find "invalid regular expression"
                                                              1 true)))))))
          ;; ---- eval-criteria ----
          (describe "eval-criteria"
                    (fn []
                      (it "empty criteria always passes"
                          (fn []
                            (assert.is_true (expr.eval-criteria (ctx) []))))
                      (it "all must pass (AND)"
                          (fn []
                            (assert.is_true (expr.eval-criteria (ctx)
                                                                [{:condition "$statusCode == 200"}
                                                                 {:condition "$statusCode != 500"}]))
                            (assert.is_false (expr.eval-criteria (ctx)
                                                                 [{:condition "$statusCode == 200"}
                                                                  {:condition "$statusCode == 500"}])))))))

;; ---- simple condition grammar ----

(describe "eval-criterion simple grammar"
          (fn []
            (let [ctx {:inputs {}
                       :steps {}
                       :workflows {}
                       :response {:status 200
                                  :headers {}
                                  :body {:state "active"
                                         :ok true
                                         :n 3
                                         :s "a && b"
                                         :evil "x\" || \"a\" == \"a"}}}
                  check #(expr.eval-criterion ctx {:condition $})]
              (it "does not let response data change the condition"
                  (fn []
                    (assert.is_false (check "$response.body#/evil == \"safe\""))))
              (it "supports single-quoted strings"
                  (fn []
                    (assert.is_true (check "$response.body#/state == 'active'"))))
              (it "keeps operators inside string literals"
                  (fn []
                    (assert.is_true (check "$response.body#/s == 'a && b'"))))
              (it "groups with parentheses"
                  (fn []
                    (assert.is_true (check "($statusCode == 201 || $statusCode == 200) && $response.body#/ok == true"))
                    (assert.is_false (check "$statusCode == 201 || ($statusCode == 200 && $response.body#/ok == false)"))))
              (it "negates with !"
                  (fn []
                    (assert.is_true (check "!($statusCode == 500)"))
                    (assert.is_false (check "!$response.body#/ok"))))
              (it "binds && tighter than ||"
                  (fn []
                    (assert.is_true (check "$statusCode == 200 || $statusCode == 1 && $statusCode == 2"))))
              (it "compares with null"
                  (fn []
                    (assert.is_true (check "$response.body#/missing == null"))
                    (assert.is_true (check "$response.body#/state != null"))))
              (it "treats a bare expression as a truthiness test"
                  (fn [] (assert.is_true (check "$response.body#/ok"))))
              (it "compares numbers numerically"
                  (fn [] (assert.is_true (check "$response.body#/n < 10"))))
              (it "fails malformed conditions, saying why"
                  (fn []
                    (each [_ c (ipairs ["$statusCode =="
                                        "($statusCode == 200"
                                        "$statusCode == 200 junk =="])]
                      (let [(passed why) (expr.eval-criterion ctx
                                                              {:condition c})]
                        (assert.is_false passed)
                        (assert.is_truthy why c))))))))

(describe "ordered comparisons with numeric strings"
          (fn []
            (let [ctx {:response {:status 200
                                  :headers {:x-count "10"}
                                  :body {:n 5
                                         :items [{:id "a,b" :v 1}
                                                 {:id "c" :v 2}]}}}
                  check #(expr.eval-criterion ctx {:condition $})]
              (it "compares a numeric header with a number"
                  (fn []
                    (assert.is_true (check "$response.header.X-Count > 5"))))
              (it "compares a number with a numeric string literal"
                  (fn [] (assert.is_true (check "$response.body#/n > '3'"))))
              (it "reports a stray null token readably"
                  (fn []
                    (let [(passed why) (check "$statusCode == 200 null")]
                      (assert.is_false passed)
                      (assert.is_truthy (: (tostring why) :find
                                           "unexpected 'null'" 1 true)))))
              (it "knows no $find: Arazzo has no such expression"
                  (fn []
                    (assert.has.error #(expr.resolve-expr ctx
                                                          "$find($response.body#/items, id, 'c', v)")
                                      "unknown runtime expression: $find($response.body#/items, id, 'c', v)"))))))

;; ---- expr: json-pointer ----

(describe "json-pointer on nil"
          (fn []
            (it "returns nil for nil obj"
                (fn []
                  (assert.is_nil (expr.json-pointer nil "/a"))))))

;; ---- expr: resolve-expr ----

(describe "resolve-expr"
          (fn []
            (let [ctx {:inputs {:x "hello" :n 7}
                       :steps {:s1 {:outputs {:k "v"}
                                    :response {:status 201
                                               :headers {:x-id "abc"}
                                               :body {:msg "hi"}}
                                    :request {:body {:q "search"} :headers {}}}}
                       :workflows {}
                       :response {:status 200
                                  :headers {:content-type "application/json"}
                                  :body {:result "ok"}}
                       :request {:body {:payload "data"} :headers {}}}]
              (it "resolves $inputs.x"
                  (fn []
                    (assert.are.equal "hello"
                                      (expr.resolve-expr ctx "$inputs.x"))))
              (it "resolves $statusCode"
                  (fn []
                    (assert.are.equal 200 (expr.resolve-expr ctx "$statusCode"))))
              (it "resolves $response.body (no pointer) as full table"
                  (fn []
                    (assert.are.same {:result "ok"}
                                     (expr.resolve-expr ctx "$response.body"))))
              (it "resolves $response.body#/result"
                  (fn []
                    (assert.are.equal "ok"
                                      (expr.resolve-expr ctx
                                                         "$response.body#/result"))))
              (it "resolves $response.header.content-type"
                  (fn []
                    (assert.are.equal "application/json"
                                      (expr.resolve-expr ctx
                                                         "$response.header.content-type"))))
              (it "resolves $steps.s1.outputs.k"
                  (fn []
                    (assert.are.equal "v"
                                      (expr.resolve-expr ctx
                                                         "$steps.s1.outputs.k"))))
              (it "resolves $steps.s1.response.body (no pointer)"
                  (fn []
                    (assert.are.same {:msg "hi"}
                                     (expr.resolve-expr ctx
                                                        "$steps.s1.response.body"))))
              (it "resolves $steps.s1.response.body#/msg"
                  (fn []
                    (assert.are.equal "hi"
                                      (expr.resolve-expr ctx
                                                         "$steps.s1.response.body#/msg"))))
              (it "resolves response headers case-insensitively"
                  (fn []
                    (assert.are.equal "application/json"
                                      (expr.resolve-expr ctx
                                                         "$response.header.Content-Type"))
                    (assert.are.equal "abc"
                                      (expr.resolve-expr ctx
                                                         "$steps.s1.response.header.X-Id"))))
              (it "resolves $steps.s1.response.header.x-id"
                  (fn []
                    (assert.are.equal "abc"
                                      (expr.resolve-expr ctx
                                                         "$steps.s1.response.header.x-id"))))
              (it "resolves $request.body (no pointer) as full table"
                  (fn []
                    (assert.are.same {:payload "data"}
                                     (expr.resolve-expr ctx "$request.body"))))
              (it "resolves $steps.s1.request.body#/q"
                  (fn []
                    (assert.are.equal "search"
                                      (expr.resolve-expr ctx
                                                         "$steps.s1.request.body#/q"))))
              (it "errors on non-expression string"
                  (fn []
                    (assert.has.error (fn []
                                        (expr.resolve-expr ctx "notanexpr"))))))))

;; ---- expr: eval-template ----

(describe "eval-template"
          (fn []
            (let [ctx {:inputs {:env "prod" :v 3}
                       :steps {}
                       :workflows {}
                       :response nil
                       :request nil}]
              (it "substitutes single expression"
                  (fn []
                    (assert.are.equal "env=prod"
                                      (expr.eval-template ctx
                                                          "env={$inputs.env}"))))
              (it "substitutes multiple expressions"
                  (fn []
                    (assert.are.equal "prod-3"
                                      (expr.eval-template ctx
                                                          "{$inputs.env}-{$inputs.v}"))))
              (it "leaves non-expression text unchanged"
                  (fn []
                    (assert.are.equal "hello world"
                                      (expr.eval-template ctx "hello world"))))
              (it "replaces unknown expr with empty string"
                  (fn []
                    (assert.are.equal "val="
                                      (expr.eval-template ctx
                                                          "val={$inputs.missing}")))))))

;; ---- expr: eval-criterion simple ----

(describe "eval-criterion ordered comparisons"
          (fn []
            (let [ctx {:inputs {}
                       :steps {}
                       :workflows {}
                       :response {:status 404 :headers {} :body {:count 5}}
                       :request nil}]
              (it "!= fails"
                  (fn []
                    (assert.is_false (expr.eval-criterion ctx
                                                          {:condition "$statusCode != 404"}))))
              (it "> passes"
                  (fn []
                    (assert.is_true (expr.eval-criterion ctx
                                                         {:condition "$response.body#/count > 4"}))))
              (it "> fails"
                  (fn []
                    (assert.is_false (expr.eval-criterion ctx
                                                          {:condition "$response.body#/count > 5"}))))
              (it ">= passes on equal"
                  (fn []
                    (assert.is_true (expr.eval-criterion ctx
                                                         {:condition "$response.body#/count >= 5"}))))
              (it "< passes"
                  (fn []
                    (assert.is_true (expr.eval-criterion ctx
                                                         {:condition "$response.body#/count < 10"}))))
              (it "<= passes on equal"
                  (fn []
                    (assert.is_true (expr.eval-criterion ctx
                                                         {:condition "$response.body#/count <= 5"})))))))

;; ---- expr: $find ----

(describe "expr $workflows"
          (fn []
            (it "resolves $workflows.id.outputs.key"
                (fn []
                  (let [ctx {:inputs {}
                             :steps {}
                             :workflows {:myWf {:outputs {:token "wf-tok"}}}
                             :response nil
                             :request nil}]
                    (assert.are.equal "wf-tok"
                                      (expr.resolve-expr ctx
                                                         "$workflows.myWf.outputs.token")))))
            (it "returns nil for unknown workflow"
                (fn []
                  (let [ctx {:inputs {}
                             :steps {}
                             :workflows {}
                             :response nil
                             :request nil}]
                    (assert.is_nil (expr.resolve-expr ctx
                                                      "$workflows.missing.outputs.x")))))))

;; ---- expr: regex criterion ----

(describe "eval-criterion regex on body fields"
          (fn []
            (let [ctx {:inputs {}
                       :steps {}
                       :workflows {}
                       :response {:status 201 :headers {} :body {}}
                       :request nil}]
              (it "matches on string body field"
                  (fn []
                    (let [ctx2 {:inputs {}
                                :steps {}
                                :workflows {}
                                :response {:status 200
                                           :headers {}
                                           :body {:msg "hello world"}}
                                :request nil}]
                      (assert.is_true (expr.eval-criterion ctx2
                                                           {:type :regex
                                                            :context "$response.body#/msg"
                                                            :condition "world"}))))))))

(describe "names with dots"
          (fn []
            (let [ctx {:inputs {:user {:name "Ann"} "a.b" 1}
                       :steps {:s {:outputs {:pet {:name "Rex"} "x.y" 2}}}
                       :workflows {:w {:outputs {:r {:id 3}}}}}]
              (it "reach into a value with a JSON pointer"
                  (fn []
                    (assert.are.equal "Rex"
                                      (expr.eval ctx
                                                 "$steps.s.outputs.pet#/name"))
                    (assert.are.equal "Ann"
                                      (expr.eval ctx "$inputs.user#/name"))
                    (assert.are.equal 3
                                      (expr.eval ctx
                                                 "$workflows.w.outputs.r#/id"))))
              (it "name inputs and outputs whose names contain dots"
                  (fn []
                    (assert.are.equal 1 (expr.eval ctx "$inputs.a.b"))
                    (assert.are.equal 2 (expr.eval ctx "$steps.s.outputs.x.y"))))
              (it "point to the JSON pointer form instead of ignoring the rest"
                  (fn []
                    (assert.has.error #(expr.eval ctx
                                                  "$steps.s.outputs.pet.name")
                                      "$steps.s.outputs.pet.name: there is no output 'pet.name'; for a value inside 'pet' use $steps.s.outputs.pet#/name")
                    (assert.has.error #(expr.eval ctx "$inputs.user.name")
                                      "$inputs.user.name: there is no input 'user.name'; for a value inside 'user' use $inputs.user#/name")
                    (assert.has.error #(expr.eval ctx
                                                  "$workflows.w.outputs.r.id")
                                      "$workflows.w.outputs.r.id: there is no output 'r.id'; for a value inside 'r' use $workflows.w.outputs.r#/id"))))))

(describe "expressions embedded in JSONPath"
          (fn []
            (local json (require :ezu.json))

            (fn ctx [inputs]
              {: inputs
               :response {:status 200
                          :headers {}
                          :body {:items [{:name "O'Brien" :size 3 :id "a"}
                                         {:name "say \"hi\"" :size 4 :id "b"}
                                         {:name "plain" :size 5 :id "c"}]}}
               :steps {}
               :workflows {}})

            (fn passes? [inputs condition]
              (expr.eval-criterion (ctx inputs)
                                   {:context "$response.body"
                                    :type :jsonpath
                                    : condition}))

            (it "are values inside string literals, whatever quotes they hold"
                (fn []
                  (assert.is_true (passes? {:name "O'Brien"}
                                           "$.items[?@.name == '{$inputs.name}']"))
                  (assert.is_true (passes? {:name "say \"hi\""}
                                           "$.items[?@.name == \"{$inputs.name}\"]"))))
            (it "can't change the query"
                (fn []
                  (assert.is_false (passes? {:name "x' || @.name != 'y"}
                                            "$.items[?@.name == '{$inputs.name}']"))
                  (assert.is_false (passes? {:name "x\\' || @.size > 0 || @.name == '"}
                                            "$.items[?@.name == '{$inputs.name}']"))))
            (it "are JSON literals outside string literals"
                (fn []
                  (assert.is_true (passes? {:size 4}
                                           "$.items[?@.size == {$inputs.size}]"))
                  (assert.is_false (passes? {:size "4"}
                                            "$.items[?@.size == {$inputs.size}]"))
                  (assert.is_false (passes? {}
                                            "$.items[?@.size == {$inputs.size}]"))))
            (it "are empty strings inside literals when missing"
                (fn []
                  (assert.is_true (passes? {}
                                           "$.items[?'{$inputs.kind}' == '']"))))
            (it "work in selectors, and show escaped in explanations"
                (fn []
                  (assert.are.same ["a"]
                                   (expr.eval (ctx {:name "O'Brien"})
                                              {:context "$response.body"
                                               :selector "$.items[?@.name == '{$inputs.name}'].id"
                                               :type "jsonpath"}))
                  (assert.is_truthy (: (expr.explain-criterion (ctx {:name "it's"})
                                                               {:context "$response.body"
                                                                :type :jsonpath
                                                                :condition "$.items[?@.name == '{$inputs.name}']"})
                                       :find "== 'it\\'s'" 1 true))))))

(describe "payload evaluation"
          (fn []
            (local json (require :ezu.json))
            (it "keeps arrays arrays, empty ones included"
                (fn []
                  (let [v (expr.eval {:inputs {:n 1}}
                                     {:tags (json.array [])
                                      :ids (json.array [1 2])
                                      :n "$inputs.n"})]
                    (assert.are.equal "{\"ids\":[1,2],\"n\":1,\"tags\":[]}"
                                      (json.encode v)))))
            (it "keeps a whole payload whose members resolve to nothing"
                (fn []
                  (assert.are.equal "{}"
                                    (json.encode (expr.eval {:inputs {}}
                                                            {:name "$inputs.name"})))
                  (assert.are.equal "[]"
                                    (json.encode (expr.eval {:inputs {}}
                                                            (json.array [{:name "$inputs.tag"}]))))))
            (it "leaves out array items that resolve to nothing, and an array left empty"
                (fn []
                  (let [v (expr.eval {:inputs {:g "sg1"}}
                                     {:items (json.array ["$inputs.a"
                                                          "x"
                                                          json.null
                                                          {:name "$inputs.b"}
                                                          {:id "$inputs.g"}])
                                      :groups (json.array [{:id "$inputs.missing"}])
                                      :nested (json.array [(json.array ["$inputs.a"])])
                                      :tags (json.array [])})]
                    (assert.are.equal "{\"items\":[\"x\",null,{\"id\":\"sg1\"}],\"tags\":[]}"
                                      (json.encode v)))))
            (it "cuts long text between characters"
                (fn []
                  (assert.are.equal "éé…" (expr.cut "ééé" 2))
                  (assert.are.equal "éé" (expr.cut "éé" 2))))
            (it "leaves out an object whose members all resolve to nothing"
                (fn []
                  (let [v (expr.eval {:inputs {:n 1}}
                                     {:n "$inputs.n"
                                      :key {:name "$inputs.key"}
                                      :deep {:a {:b "$inputs.missing"}}
                                      :part {:name "$inputs.key"
                                             :n "$inputs.n"}
                                      :empty {}})]
                    (assert.are.equal "{\"empty\":{},\"n\":1,\"part\":{\"n\":1}}"
                                      (json.encode v)))))))

(describe "condition syntax errors"
          (fn []
            (it "say what is wrong, not where in ezu"
                (fn []
                  (let [(_ problem) (expr.eval-criterion {:inputs {}}
                                                         {:condition "$statusCode =="})]
                    (assert.are.equal "condition '$statusCode ==' can't be evaluated: unexpected end in condition: $statusCode =="
                                      problem))
                  (let [(_ problem) (expr.eval-criterion {:inputs {}}
                                                         {:condition "$statusCode ~ 1"})]
                    (assert.are.equal "condition '$statusCode ~ 1' can't be evaluated: unexpected character '~' in condition: $statusCode ~ 1"
                                      problem))
                  (let [(_ problem) (expr.eval-criterion {:inputs {}}
                                                         {:condition "$statusCode == 'a"})]
                    (assert.are.equal "condition '$statusCode == 'a' can't be evaluated: unterminated string in condition: $statusCode == 'a"
                                      problem))))))

(describe "explain-criterion"
          (fn []
            (let [ctx {:inputs {}
                       :response {:status 403
                                  :headers {}
                                  :body {:state "pending" :n 3}}
                       :steps {}
                       :workflows {}}]
              (it "shows the values of a simple condition's expressions"
                  (fn []
                    (assert.are.equal "$statusCode == 200 ($statusCode is 403)"
                                      (expr.explain-criterion ctx
                                                              {:condition "$statusCode == 200"}))
                    (assert.are.equal "$response.body#/state == 'success' ($response.body#/state is \"pending\")"
                                      (expr.explain-criterion ctx
                                                              {:condition "$response.body#/state == 'success'"}))))
              (it "says when an expression has no value"
                  (fn []
                    (assert.are.equal "$response.body#/gone == 1 ($response.body#/gone is missing)"
                                      (expr.explain-criterion ctx
                                                              {:condition "$response.body#/gone == 1"}))))
              (it "names each expression once"
                  (fn []
                    (assert.are.equal "$response.body#/n > 5 && $response.body#/n < 10 ($response.body#/n is 3)"
                                      (expr.explain-criterion ctx
                                                              {:condition "$response.body#/n > 5 && $response.body#/n < 10"}))))
              (it "shows the context of regex and JSONPath conditions"
                  (fn []
                    (assert.are.equal "regex ^2\\d{2}$ doesn't match $statusCode (403)"
                                      (expr.explain-criterion ctx
                                                              {:condition "^2\\d{2}$"
                                                               :context "$statusCode"
                                                               :type :regex}))
                    (assert.are.equal "jsonpath $.items[0] selects nothing in $response.body ({\"n\":3,\"state\":\"pending\"})"
                                      (expr.explain-criterion ctx
                                                              {:condition "$.items[0]"
                                                               :context "$response.body"
                                                               :type :jsonpath}))))
              (it "shows regex and JSONPath conditions with their expressions substituted"
                  (fn []
                    (let [named (doto (collect [k v (pairs ctx)] k v)
                                  (tset :inputs {:name "nope"}))]
                      (assert.are.equal "jsonpath $[?@.state == 'nope'] selects nothing in $response.body ({\"n\":3,\"state\":\"pending\"})"
                                        (expr.explain-criterion named
                                                                {:condition "$[?@.state == '{$inputs.name}']"
                                                                 :context "$response.body"
                                                                 :type :jsonpath}))
                      (assert.are.equal "regex ^nope$ doesn't match $response.body#/state (\"pending\")"
                                        (expr.explain-criterion named
                                                                {:condition "^{$inputs.name}$"
                                                                 :context "$response.body#/state"
                                                                 :type :regex})))))
              (it "shortens long values"
                  (fn []
                    (let [long-ctx (doto (collect [k v (pairs ctx)] k v)
                                     (tset :response
                                           {:status 200
                                            :headers {}
                                            :body {:s (string.rep "x" 200)}}))
                          text (expr.explain-criterion long-ctx
                                                       {:condition "$response.body#/s == 'y'"})]
                      (assert.is_true (< (length text) 140))
                      (assert.is_truthy (text:find "…" 1 true)))))
              (it "shortens text that isn't UTF-8"
                  (fn []
                    (assert.is_truthy (: (expr.brief (.. (string.rep "x" 100)
                                                         "\255"))
                                         :find "…" 1 true))))
              (it "says why a condition can't be evaluated"
                  (fn []
                    (assert.is_truthy (: (expr.explain-criterion ctx
                                                                 {:condition "$statuscode == 200"})
                                         :find
                                         "can't be evaluated: unknown runtime expression: $statuscode"
                                         1 true)))))))

(describe "condition language, as the Arazzo spec defines it"
          (fn []
            (let [ctx {:inputs {:a "it's"}
                       :response {:status 200
                                  :headers {}
                                  :body {:state "DONE"}}
                       :steps {}
                       :workflows {}}]
              (it "compares strings case-insensitively"
                  (fn []
                    (assert.is_true (expr.eval-criterion ctx
                                                         {:condition "$response.body#/state == 'done'"}))
                    (assert.is_false (expr.eval-criterion ctx
                                                          {:condition "$response.body#/state != 'Done'"}))))
              (it "escapes a single quote by doubling it"
                  (fn []
                    (assert.is_true (expr.eval-criterion ctx
                                                         {:condition "$inputs.a == 'it''s'"}))))
              (it "never matches a regex against a missing value"
                  (fn []
                    (assert.is_false (expr.eval-criterion ctx
                                                          {:context "$response.header.X"
                                                           :type "regex"
                                                           :condition "^n"})))))))

(describe "expression roots"
          (fn []
            (let [ctx {:inputs {}
                       :request {:query {:q "x"} :path {:id "7"} :headers {}}
                       :response {:status 200 :headers {}}
                       :steps {}
                       :workflows {}}]
              (it "read the request's query and path parameters"
                  (fn []
                    (assert.are.equal "x" (expr.eval ctx "$request.query.q"))
                    (assert.are.equal "7" (expr.eval ctx "$request.path.id"))))
              (it "reject a root that doesn't exist instead of reading nil"
                  (fn []
                    (let [(passed why) (expr.eval-criterion ctx
                                                            {:condition "$statuscode == 200"})]
                      (assert.is_false passed)
                      (assert.is_truthy (: why :find
                                           "unknown runtime expression: $statuscode"
                                           1 true)))))
              (it "reject misspelled parts instead of reading nil or too much"
                  (fn []
                    (let [c (doto (collect [k v (pairs ctx)] k v)
                              (tset :response
                                    {:status 200
                                     :headers {}
                                     :body {:status "ok"}})
                              (tset :steps {:s1 {:outputs {:id 1}}}))]
                      (each [_ e (ipairs ["$response.bdy#/status"
                                          "$response.body.status"
                                          "$response.header"
                                          "$steps.s1.output.id"
                                          "$workflows.w.output.x"])]
                        (let [(ok err) (pcall expr.eval c e)]
                          (assert.is_false ok e)
                          (assert.is_truthy (: (tostring err) :find
                                               (.. "unknown runtime expression: "
                                                   e)
                                               1 true)
                                            (tostring err)))))))
              (it "leave payload text that merely starts with $ as it is"
                  (fn []
                    (assert.are.same {:price "$5" :code 200}
                                     (expr.eval ctx
                                                {:price "$5"
                                                 :code "$statusCode"})))))))

;; ---- Arazzo 1.1 ----

(fn shop []
  {:inputs {:sku "b" :limit 2}
   :response {:status 200
              :headers {}
              :body {:items [{:sku "a" :qty 1}
                             {:sku "b" :qty 5}
                             {:sku "c" :qty 9}]
                     :user {:name "Rex"}}}
   :steps {}
   :workflows {:prep {:inputs {:zone "de"} :outputs {}}}
   :outputs {:total 15}
   :self "https://flows.test/shop.arazzo.yaml"
   :sources {:shop {:name "shop"
                    :url "https://api.test/openapi.json"
                    :type "openapi"}}})

(describe "Selector Objects"
          (fn []
            (it "select with a singular JSONPath query: its node's value, or nothing"
                (fn []
                  (assert.are.equal "Rex"
                                    (expr.eval (shop)
                                               {:context "$response.body"
                                                :selector "$.user.name"
                                                :type "jsonpath"}))
                  (assert.are.equal 1
                                    (expr.eval (shop)
                                               {:context "$response.body"
                                                :selector "$.items[0].qty"
                                                :type "jsonpath"}))
                  (assert.is_nil (expr.eval (shop)
                                            {:context "$response.body"
                                             :selector "$.user.nope"
                                             :type "jsonpath"}))))
            (it "select with any other query an array, whatever the nodes"
                (fn []
                  (let [json (require :ezu.json)
                        select #(expr.eval (shop)
                                           {:context "$response.body"
                                            :selector $
                                            :type "jsonpath"})
                        one (select "$.items[?@.sku == '{$inputs.sku}'].qty")
                        none (select "$.items[?@.qty > 99]")]
                    (assert.are.same [5] one)
                    (assert.is_true (json.array? one))
                    (assert.are.same [5 9] (select "$.items[?@.qty > 2].qty"))
                    (assert.are.equal "[]" (json.encode none)))))
            (it "select with a JSON Pointer"
                (fn []
                  (assert.are.equal "Rex"
                                    (expr.eval (shop)
                                               {:context "$response.body"
                                                :selector "/user/name"
                                                :type "jsonpointer"}))))
            (it "take an Expression Type Object, of the versions ezu knows"
                (fn []
                  (assert.are.equal "Rex"
                                    (expr.eval (shop)
                                               {:context "$response.body"
                                                :selector "$.user.name"
                                                :type {:type "jsonpath"
                                                       :version "rfc9535"}}))
                  (let [(ok err) (pcall expr.eval (shop)
                                        {:context "$response.body"
                                         :selector "$.user.name"
                                         :type {:type "jsonpath"
                                                :version "draft-goessner-dispatch-jsonpath-00"}})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find "not supported" 1
                                         true)))
                  (let [(ok err) (pcall expr.eval (shop)
                                        {:context "$response.body"
                                         :selector "/root"
                                         :type "xpath"})]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find "XPath" 1 true)))))
            (it "work inside payloads, and tables that aren't selectors stay data"
                (fn []
                  (assert.are.same {:name "Rex"
                                    :plain {:context "x" :type "y"}}
                                   (expr.eval (shop)
                                              {:name {:context "$response.body"
                                                      :selector "$.user.name"
                                                      :type "jsonpath"}
                                               :plain {:context "x" :type "y"}}))))))

(describe "JSONPath criteria"
          (fn []
            (let [check #(expr.eval-criterion (shop)
                                              {:context "$response.body"
                                               :condition $1
                                               :type (or $2 "jsonpath")})]
              (it "pass when the query selects something"
                  (fn []
                    (assert.is_true (check "$.items[?@.qty > 8]"))
                    (assert.is_false (check "$.items[?@.qty > 99]"))
                    (assert.is_true (check "$[?count(@.*) > 2]"))))
              (it "embed runtime expressions"
                  (fn []
                    (assert.is_true (check "$.items[?@.sku == '{$inputs.sku}']"))))
              (it "take an Expression Type Object"
                  (fn []
                    (assert.is_true (check "$.user"
                                           {:type "jsonpath"
                                            :version "rfc9535"}))))
              (it "fail on a missing context or a malformed query, saying why"
                  (fn []
                    (let [(passed why) (check "$.items[?@.qty >]")]
                      (assert.is_false passed)
                      (assert.is_truthy (: (tostring why) :find
                                           "invalid JSONPath" 1 true)))
                    (assert.is_false (expr.eval-criterion (shop)
                                                          {:context "$response.body#/nope"
                                                           :condition "$"
                                                           :type "jsonpath"}))))
              (it "report what fails through the context's warn"
                  (fn []
                    (let [warnings []
                          ctx (doto (shop)
                                (tset :warn #(table.insert warnings $)))]
                      (assert.is_false (expr.eval-criteria ctx
                                                           [{:condition "$statuscode == 200"}]))
                      (assert.are.equal 1 (length warnings))))))))

(describe "Arazzo 1.1 expressions"
          (fn []
            (it "embed runtime expressions in regex conditions"
                (fn []
                  (assert.is_true (expr.eval-criterion (shop)
                                                       {:context "$response.body#/user/name"
                                                        :condition "^{$response.body#/user/name}$"
                                                        :type :regex}))))
            (it "resolve $outputs, $workflows inputs, $self and source fields"
                (fn []
                  (assert.are.equal 15 (expr.eval (shop) "$outputs.total"))
                  (assert.are.equal "de"
                                    (expr.eval (shop)
                                               "$workflows.prep.inputs.zone"))
                  (assert.are.equal "https://flows.test/shop.arazzo.yaml"
                                    (expr.eval (shop) "$self"))
                  (assert.are.equal "https://api.test/openapi.json/x"
                                    (expr.eval (shop)
                                               "{$sourceDescriptions.shop.url}/x"))))
            (it "refuse AsyncAPI messages"
                (fn []
                  (let [(ok err) (pcall expr.eval (shop) "$message.payload")]
                    (assert.is_false ok)
                    (assert.is_truthy (: (tostring err) :find "AsyncAPI" 1 true)))))))
