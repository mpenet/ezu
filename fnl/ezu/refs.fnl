;; ABOUTME: Resolves $refs in OpenAPI and Arazzo documents: local JSON
;; ABOUTME: pointers, references into other files or URLs; recursion stays cyclic.
(local util (require :ezu.util))
(local json (require :ezu.json))

(fn split-ref [ref]
  "(document-part pointer) of a $ref; the pointer is percent-decoded."
  (let [(doc fragment) (ref:match "^([^#]*)#?(.*)$")]
    (values doc (util.percent-decode fragment))))

;; members whose values are example or schema data, where $ref is plain data
(local data-keys {:example true :default true :enum true :const true})

;; maps whose keys are names chosen by the author (a property, a response or
;; a component may be called default or example)
(local name-maps {:properties true
                  :patternProperties true
                  :dependentSchemas true
                  :$defs true
                  :definitions true
                  :responses true
                  :schemas true
                  :parameters true
                  :examples true
                  :requestBodies true
                  :headers true
                  :securitySchemes true
                  :links true
                  :callbacks true
                  :pathItems true
                  :variables true
                  :mapping true
                  :content true
                  :encoding true
                  :webhooks true
                  :paths true})

;; maps whose values are schemas: a schema there may be called examples
(local schema-maps {:properties true
                    :patternProperties true
                    :dependentSchemas true
                    :$defs true
                    :definitions true
                    :schemas true})

(fn data? [k key parent grandparent]
  "Whether member k of the value at key (under parent, itself under
grandparent) is data: an example, a default, an enum, a const, an element of
a JSON Schema examples array, or an OpenAPI Example's value."
  (or (and (. data-keys k) (not (. name-maps key)))
      (and (= (type k) :number) (= key :examples))
      (and (= k :value) (= parent :examples) (not (. schema-maps grandparent)))))

;; keywords that describe rather than constrain: next to a $ref, they replace
;; the target's
(local annotations {:title true
                    :description true
                    :summary true
                    :default true
                    :example true
                    :examples true
                    :deprecated true
                    :readOnly true
                    :writeOnly true
                    :$comment true})

(fn with-siblings [target siblings]
  "target with the keywords written next to the $ref naming it, as JSON Schema
2020-12 applies them: annotations replace the target's, other keywords are
added, and where both have one, both must hold (allOf). target stays as it is."
  (let [merged (setmetatable (collect [k v (pairs target)] k v)
                             (getmetatable target))
        both {}]
    (each [k v (pairs siblings)]
      (if (or (. annotations k) (= nil (. merged k))) (tset merged k v)
          (not= v (. merged k)) (tset both k v)))
    (if (next both)
        (doto (collect [k v (pairs siblings)]
                (when (. annotations k) (values k v)))
          (tset :allOf (json.array [merged both])))
        merged)))

(fn pointer-keys [pointer]
  "The last three segments of a JSON pointer, unescaped, last first."
  (let [segs (icollect [seg (pointer:gmatch "/([^/]*)")]
               (util.unescape-pointer seg))
        n (length segs)]
    (values (. segs n) (. segs (- n 1)) (. segs (- n 2)))))

(fn resolver [root ?opts]
  "Returns (fn [value]) giving value with every $ref replaced by its target.
?opts: {:base location-of-root :load (fn [location] parsed-document)}.
Refs into other documents resolve relative to the document holding them;
each document is loaded once. Every ref to the same place yields the same
table, so recursive schemas come out as cyclic tables. Refs that point
nowhere, or only at each other, raise."
  (let [opts (or ?opts {})
        ;; the root counts as loaded, so refs back to it reuse it
        documents (if opts.base {opts.base root} {})]
    (fn document-at [from ref doc-part]
      (if (= doc-part "")
          from
          (let [base (or from.base (error (.. "cannot resolve $ref '" ref
                                              "': the schema's location is unknown")
                                          0))
                location (util.resolve-reference base doc-part)]
            (when (= nil (. documents location))
              (assert opts.load (.. "cannot resolve $ref '" ref "': no loader"))
              (tset documents location (opts.load location)))
            {:root (. documents location) :base location})))

    ;; one expansion per ref, shared by all its uses; recursive schemas
    ;; become cyclic tables
    (local cache {})

    (fn ref-target [from ref]
      "(target-document value key) for ref."
      (let [(doc-part pointer) (split-ref ref)]
        (when (and (not= pointer "") (not= (pointer:sub 1 1) "/"))
          (error (.. "unsupported $ref '" ref
                     "': the fragment must be a JSON pointer like #/a/b")
                 0))
        (let [target (document-at from ref doc-part)
              value (util.json-pointer target.root pointer)]
          (when (= nil value)
            (error (.. "unresolved $ref '" ref "'"
                       (if target.base
                           (.. " in " (util.redact-url target.base))
                           "")) 0))
          (values target value (.. (or target.base "") "#" pointer) pointer))))

    (fn ref-of [value]
      (when (= (type value) :table)
        (let [ref (. value "$ref")]
          (when (= (type ref) :string) ref))))

    (var deref nil)
    ;; tables already copied during the current call, so that values that are
    ;; already cyclic are copied as cycles
    (var copies {})

    (fn resolve-ref [from ref ?key ?parent ?grandparent]
      ;; ?key ?parent ?grandparent: where the $ref is; the target's members
      ;; are data when either that place or the target's own says so
      ;; follow refs to refs to the value they finally name
      (var (target value key pointer) (ref-target from ref))
      (let [chain [key]]
        (while (and (= nil (. cache key)) (ref-of value))
          (let [next-ref (ref-of value)]
            (set (target value key pointer) (ref-target target next-ref))
            (when (accumulate [found false _ k (ipairs chain) &until found]
                    (= k key))
              (error (.. "circular $ref: " (table.concat chain " -> ") " -> "
                         key) 0))
            (table.insert chain key)))
        (let [cached (. cache key)
              expanded (if (not= nil cached) cached
                           (or (not= (type value) :table) (= value json.null))
                           value ;; registered before it is filled, so recursion
                           ;; comes back to this same table
                           (let [out (setmetatable {} (getmetatable value))
                                 (name parent grandparent) (pointer-keys pointer)]
                             (tset cache key out)
                             (each [k v (pairs value)]
                               (tset out k
                                     (if (or (data? k name parent grandparent)
                                             (data? k ?key ?parent ?grandparent))
                                         v
                                         (deref target v k name parent))))
                             out))]
          (each [_ k (ipairs chain)]
            (tset cache k expanded))
          expanded)))

    (set deref (fn [from value ?key ?parent ?grandparent]
                 (match (ref-of value)
                   ref (let [target (resolve-ref from ref ?key ?parent
                                                 ?grandparent)
                             siblings (collect [k v (pairs value)]
                                        (when (not= k "$ref")
                                          (values k
                                                  (if (data? k ?key ?parent
                                                             ?grandparent)
                                                      v
                                                      (deref from v k ?key
                                                             ?parent)))))]
                         (if (and (next siblings) (= (type target) :table)
                                  (not= target json.null))
                             (with-siblings target siblings)
                             target))
                   _ (if (or (not= (type value) :table) (= value json.null))
                         value
                         (. copies value)
                         (. copies value)
                         ;; the copy keeps the table's metatable (JSON arrays)
                         (let [out (setmetatable {} (getmetatable value))]
                           (tset copies value out)
                           (each [k v (pairs value)]
                             (tset out k
                                   (if (data? k ?key ?parent ?grandparent) v
                                       (deref from v k ?key ?parent))))
                           out)))))
    (fn [value]
      (set copies {})
      (deref {: root :base opts.base} value))))

{: resolver}
