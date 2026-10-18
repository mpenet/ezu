;; ABOUTME: Specs for ezu.json: decoded arrays stay arrays (even empty ones)
;; ABOUTME: through printing, validation, YAML and re-encoding.
(local json (require :ezu.json))
(local pretty (require :ezu.pretty))
(local yaml (require :ezu.yaml))
(local validate (require :ezu.validate))
(local http (require :ezu.http))

(describe "ezu.json"
          (fn []
            (it "keeps empty arrays and objects apart when re-encoding"
                (fn []
                  (let [v (json.decode "{\"a\":[],\"b\":{},\"c\":[[],{}]}")]
                    (assert.is_true (json.array? v.a))
                    (assert.is_false (json.array? v.b))
                    (assert.are.same {:a "[]" :b "{}" :c "[[],{}]"}
                                     (collect [k x (pairs v)]
                                       k
                                       (json.encode x))))))
            (it "marks tables built in Lua as arrays"
                (fn []
                  (assert.are.equal "{\"tags\":[]}"
                                    (json.encode {:tags (json.array [])}))
                  (assert.are.equal "[1,2]" (json.encode (json.array [1 2])))))
            (it "leaves array contents untouched"
                (fn []
                  (let [v (json.decode "[10,20]")]
                    (assert.are.same [10 20] (icollect [_ x (ipairs v)] x))
                    (assert.is_nil (rawget v 0))
                    (assert.are.equal 2 (length v)))))))

(describe "json.encode"
          (fn []
            (it "writes object keys in sorted order"
                (fn []
                  (assert.are.equal "{\"a\":1,\"b\":{\"x\":true,\"y\":[]},\"c\":\"s\"}"
                                    (json.encode {:c "s"
                                                  :a 1
                                                  :b {:y (json.array [])
                                                      :x true}}))))
            (it "writes integers exactly"
                (fn []
                  (assert.are.equal "[1234567890123456789,-42,0]"
                                    (json.encode (json.array [1234567890123456789
                                                              -42
                                                              0])))))
            (it "writes floats in their shortest exact form"
                (fn []
                  (assert.are.equal "[0.1,0.3333333333333333,1e+300,2.0,-1.5]"
                                    (json.encode (json.array [0.1
                                                              (/ 1 3)
                                                              1e300
                                                              2.0
                                                              -1.5])))))
            (it "escapes strings"
                (fn []
                  (assert.are.equal "\"q\\\"b\\\\n\\nt\\tc\\u0001é/\""
                                    (json.encode "q\"b\\n\nt\tc\1é/"))))
            (it "refuses what JSON cannot express"
                (fn []
                  (assert.has.error #(json.encode (/ 1 0)))
                  (assert.has.error #(json.encode {1.5 "x"}))
                  (let [t {}]
                    (tset t :self t)
                    (assert.has.error #(json.encode t)))))))

(describe "empty arrays elsewhere"
          (fn []
            (it "print as [] in JSON and YAML"
                (fn []
                  (let [v (json.decode "{\"a\":[],\"b\":{}}")]
                    (assert.are.equal "{\n  \"a\": [],\n  \"b\": {}\n}"
                                      (pretty.pretty v 0 false))
                    (assert.are.same v (json.decode (pretty.pretty v 0 false)))
                    (assert.is_true (json.array? (. (yaml.parse (pretty.yaml v
                                                                             0
                                                                             false))
                                                    :a))))))
            (it "come out of YAML as arrays"
                (fn []
                  (let [v (yaml.parse "a: []\nb: {}\nc:\n  - 1\n")]
                    (assert.is_true (json.array? v.a))
                    (assert.is_false (json.array? v.b))
                    (assert.are.same {:a "[]" :b "{}" :c "[1]"}
                                     (collect [k x (pairs v)]
                                       k
                                       (json.encode x))))))
            (it "validate as arrays, and empty objects as objects"
                (fn []
                  (let [v (json.decode "{\"a\":[],\"b\":{}}")]
                    (assert.are.same []
                                     (validate.check {:properties {:a {:type "array"}
                                                                   :b {:type "object"}}}
                                                     v)))))
            (it "are sent as [] in request bodies"
                (fn []
                  (let [(_ payload) (http.encode-request {:method "POST"
                                                          :url "https://h/x"
                                                          :headers {:content-type "application/json"}
                                                          :body (json.decode "{\"tags\":[]}")})]
                    (assert.are.equal "{\"tags\":[]}" payload))))
            (it "survive response decoding"
                (fn []
                  (let [r (http.decode-response 200
                                                {:content-type "application/json"}
                                                "{\"tags\":[]}")]
                    (assert.is_true (json.array? r.body.tags)))))))

(describe "JSON null"
          (fn []
            (local expr (require :ezu.arazzo.expr))
            (it "keeps its place in arrays"
                (fn []
                  (let [v (json.decode "[1,null,3]")]
                    (assert.are.equal 3 (length v))
                    (assert.are.equal json.null (. v 2))
                    (assert.are.equal "[1,null,3]" (json.encode v))
                    (assert.are.equal "[\n  1,\n  null,\n  3\n]"
                                      (pretty.pretty v 0 false)))))
            (it "drops object members by default, keeps them on request"
                (fn []
                  (assert.are.same {:b 1} (json.decode "{\"a\":null,\"b\":1}"))
                  (let [v (json.decode "{\"a\":null,\"b\":1}" true)]
                    (assert.are.equal json.null v.a)
                    (assert.are.equal "{\"a\":null,\"b\":1}" (json.encode v))
                    (assert.are.equal "{\n  \"a\": null,\n  \"b\": 1\n}"
                                      (pretty.pretty v 0 false)))))
            (it "stays in place in YAML sequences, and in mappings on request"
                (fn []
                  (let [v (yaml.parse "s: [null, a]\nm: null\n")]
                    (assert.are.equal json.null (. v.s 1))
                    (assert.are.equal 2 (length v.s))
                    (assert.is_nil v.m))
                  (assert.are.equal json.null
                                    (. (yaml.parse "m: null\n" true) :m))))
            (it "survives in response bodies"
                (fn []
                  (let [r (http.decode-response 200
                                                {:content-type "application/json"}
                                                "{\"a\":null}")]
                    (assert.are.equal json.null r.body.a))))
            (it "is the null of validation and of conditions"
                (fn []
                  (assert.are.equal json.null validate.null)
                  (assert.are.same []
                                   (validate.check {:enum [json.null "a"]} "a"))
                  (assert.is_true (expr.eval-criterion {:response {:body (json.decode "{\"a\":null}"
                                                                                      true)}}
                                                       {:condition "$response.body#/a == null"}))))))

(describe "JSON null across ezu"
          (fn []
            (local expr (require :ezu.arazzo.expr))
            (local refs (require :ezu.refs))
            (local util (require :ezu.util))
            (local request (require :ezu.cli.request))
            (local {: select-path} (require :ezu.cli.output))
            (it "is kept, not copied, by the ref resolver"
                (fn []
                  (let [schema (json.decode "{\"enum\":[\"red\",null]}")
                        v ((refs.resolver {}) schema)]
                    (assert.are.equal json.null (. v.enum 2))
                    (assert.are.same [] (validate.check v json.null)))))
            (it "survives Arazzo payloads, where a missing value in an array is left out"
                (fn []
                  (let [v (expr.eval {:inputs {:b 2}}
                                     (json.decode "{\"tags\":[\"a\",null],\"x\":[\"$inputs.b\",\"$inputs.a\"]}"
                                                  true))]
                    (assert.are.equal "{\"tags\":[\"a\",null],\"x\":[2]}"
                                      (json.encode v)))))
            (it "is a missing path parameter, and left out of queries"
                (fn []
                  (assert.has.error #(util.resolve-path "/pets/{id}"
                                                        {:id json.null})
                                    "missing required path parameter: id")
                  (assert.are.equal "a=1"
                                    (util.query-string {:a 1 :b json.null}))
                  (assert.are.equal "c=1"
                                    (util.query-string {:c (json.array [1
                                                                        json.null])}))))
            (it "never matches a regex"
                (fn []
                  (assert.is_false (expr.eval-criterion {:response {:body {:x json.null}}}
                                                        {:context "$response.body#/x"
                                                         :type "regex"
                                                         :condition "^n"}))))
            (it "is replaced by body fields set under it"
                (fn []
                  (assert.are.equal "{\"o\":{\"k\":1}}"
                                    (json.encode (request.build-body [["o.k"
                                                                       "1"]]
                                                                     nil
                                                                     (json.decode "{\"o\":null}"
                                                                                  true))))
                  (assert.has.error #(request.build-body [["s" "x"]] nil
                                                         json.null))))
            (it "matches nothing in --select paths"
                (fn []
                  (let [data (json.decode "{\"a\":null}" true)]
                    (assert.is_nil (select-path data ".a[]"))
                    (assert.is_nil (select-path data ".a.{x}"))
                    (assert.is_nil (select-path data ".a.b")))))))

(describe "JSON null, further"
          (fn []
            (local expr (require :ezu.arazzo.expr))
            (local util (require :ezu.util))
            (local coerce (require :ezu.coerce))
            (local doc (require :ezu.doc))
            (it "can't be written into"
                (fn []
                  (assert.has.error #(tset json.null :b 5))
                  (assert.is_nil (rawget json.null :b))))
            (it "leaves null object members out of queries, paths and forms"
                (fn []
                  (let [o (json.decode "{\"a\":null,\"b\":1}" true)]
                    (assert.are.equal "f[b]=1"
                                      (util.query-string {:f o}
                                                         {:f {:style "deepObject"}}))
                    (assert.are.equal "b=1" (util.query-string {:f o}))
                    (assert.are.equal "/x/1"
                                      (util.resolve-path "/x/{p}"
                                                         {:p (json.decode "[1,null]"
                                                                          true)}))
                    (assert.are.equal "a=1"
                                      (util.form-encode {:a (json.decode "[1,null]")})))))
            (it "renders in templates like a missing value; objects as JSON"
                (fn []
                  (let [ctx {:inputs {:n json.null
                                      :o (json.decode "{\"k\":1}")}}]
                    (assert.are.equal "v=" (expr.eval ctx "v={$inputs.n}"))
                    (assert.are.equal "v={\"k\":1}"
                                      (expr.eval ctx "v={$inputs.o}")))))
            (it "boolean and type-array schemas work for fields and help"
                (fn []
                  (assert.are.equal "123"
                                    (coerce.from-string "123"
                                                        {:type ["string"
                                                                "null"]}))
                  (assert.are.equal 1 (coerce.from-string "1" true))
                  (assert.is_nil (coerce.schema-at {:properties {:meta true}}
                                                   [:meta :x]))
                  (assert.is_string (doc.build "/x" "post"
                                               {:requestBody {:content {"application/json" {:schema {:properties {:meta true
                                                                                                                  :d {:type "object"
                                                                                                                      :default {:a 1}}}}}}}}))))))
