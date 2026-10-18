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

;; members whose value is one schema
(local schema-keys {:items true
                    :additionalItems true
                    :additionalProperties true
                    :unevaluatedItems true
                    :unevaluatedProperties true
                    :not true
                    :if true
                    :then true
                    :else true
                    :contains true
                    :propertyNames true
                    :contentSchema true
                    :schema true})

;; members whose value is a list of schemas
(local schema-lists {:allOf true
                     :anyOf true
                     :oneOf true
                     :prefixItems true
                     :items true})

(fn schema-position? [key parent grandparent]
  "Whether the value at key (under parent, itself under grandparent) is a
schema: a member of a map of schemas, the value of a keyword taking a schema
(an OpenAPI Parameter's, Header's or Media Type's schema among them), an
element of a list of schemas, or an Arazzo workflow's inputs."
  (or (= true (. schema-maps parent))
      (and (= true (. schema-keys key)) (not (. name-maps parent)))
      (and (not= nil key) (not= nil (tonumber key))
           (= true (. schema-lists parent)))
      (and (= key :inputs) (= grandparent :workflows))
      (and (= parent :inputs) (= grandparent :components))))

;; maps of OpenAPI Path Items
(local path-item-maps {:paths true :webhooks true :pathItems true})

;; the members of a Path Item that are operations
(local operations {:get true
                   :put true
                   :post true
                   :delete true
                   :options true
                   :head true
                   :patch true
                   :trace true})

(fn path-item-position? [key parent grandparent]
  "Whether the value at key (under parent, under grandparent) is an OpenAPI
Path Item: an entry of paths, webhooks or components.pathItems, or a
Callback's expression."
  (or (= true (. path-item-maps parent)) (= grandparent :callbacks)))

(fn copy-table [t]
  (setmetatable (collect [k v (pairs t)] k v) (getmetatable t)))

(fn union [names more]
  "The names of names, then those of more it lacks."
  (let [out (json.array (icollect [_ n (ipairs names)] n))
        seen (collect [_ n (ipairs names)] n
               true)]
    (each [_ n (ipairs more)]
      (when (not (. seen n))
        (tset seen n true)
        (table.insert out n)))
    out))

(fn merge-schema [out siblings]
  "Applies to out, a copy of a schema, the keywords written next to the $ref
naming it, as JSON Schema 2020-12 does: annotations replace the schema's,
other keywords are added, and where both have one, both must hold. required
lists are joined; properties are joined, and where both name a property,
both of its schemas must hold. What must hold besides goes in out's allOf."
  (let [both {}]
    (each [k v (pairs siblings)]
      (let [mine (. out k)]
        (if (or (. annotations k) (= nil mine))
            (tset out k v)
            (and (= k :required) (= (type mine) :table) (= (type v) :table))
            (tset out k (union mine v))
            (and (= k :properties) (= (type mine) :table) (= (type v) :table))
            (let [props (copy-table mine)
                  clashes {}]
              (each [name schema (pairs v)]
                (if (= nil (. props name)) (tset props name schema)
                    (not= schema (. props name)) (tset clashes name schema)))
              (tset out k props)
              (when (next clashes)
                (tset both :properties clashes)))
            (not= v mine)
            (tset both k v))))
    (when (next both)
      (let [all (json.array (if (= (type out.allOf) :table)
                                (icollect [_ s (ipairs out.allOf)] s)
                                []))]
        (table.insert all both)
        (tset out :allOf all)))
    out))

(fn merge-into [out target kind siblings]
  "Fills out with target and the keywords written next to the $ref naming it.
In a schema they apply as JSON Schema does (merge-schema). A Path Item's own
fields win over the referenced item's. Elsewhere, as an OpenAPI 3.1
Reference Object says, only a summary and a description replace the
target's; other keywords are ignored."
  (each [k v (pairs target)]
    (tset out k v))
  (if (= kind :schema) (merge-schema out siblings)
      (each [k v (pairs siblings)]
        (tset out k v))))

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

    (fn has-siblings? [value]
      (accumulate [found false k (pairs value) &until found]
        (not= k "$ref")))

    (var deref nil)
    ;; tables already copied during the current call, so that values that are
    ;; already cyclic are copied as cycles
    (var copies {})
    ;; refs with keywords next to them, expanded during the current call, in
    ;; the order they were met: {:out :target :kind :siblings}. Their target
    ;; may still be being filled when they are met (recursive schemas), so
    ;; they are filled once the call has expanded everything else
    (var pending [])
    (var pending-of {})
    (var expand-ref nil)

    (fn resolve-ref [from ref ?key ?parent ?grandparent]
      "(expansion name parent grandparent) of ref: name parent grandparent
are the last keys of where its expansion is."
      ;; ?key ?parent ?grandparent: where the $ref is; the target's members
      ;; are data when either that place or the target's own says so
      ;; follow refs to refs to the value they finally name, or to a ref with
      ;; keywords next to it, which is expanded with them
      (var (target value key pointer) (ref-target from ref))
      (let [chain [key]]
        (while (and (= nil (. cache key)) (ref-of value)
                    (not (has-siblings? value)))
          (let [next-ref (ref-of value)]
            (set (target value key pointer) (ref-target target next-ref))
            (when (accumulate [found false _ k (ipairs chain) &until found]
                    (= k key))
              (error (.. "circular $ref: " (table.concat chain " -> ") " -> "
                         key) 0))
            (table.insert chain key)))
        (let [cached (. cache key)
              (name parent grandparent) (pointer-keys pointer)
              ;; registered before it is filled, so recursion comes back to
              ;; this same table
              expanded (if (not= nil cached) cached (ref-of value)
                           (let [out {}]
                             (tset cache key out)
                             (expand-ref target value name parent grandparent
                                         out))
                           (or (not= (type value) :table) (= value json.null))
                           value (let [out (setmetatable {} (getmetatable value))]
                                  (tset cache key out)
                                  (each [k v (pairs value)]
                                    (tset out k
                                          (if (or (data? k name parent
                                                         grandparent)
                                                  (data? k ?key ?parent
                                                         ?grandparent))
                                              v
                                              (deref target v k name parent))))
                                  out))]
          (each [_ k (ipairs chain)]
            (tset cache k expanded))
          (values expanded name parent grandparent))))

    (set expand-ref (fn [from value ?key ?parent ?grandparent ?out]
                      "The expansion of value, a $ref with keywords next to it at ?key
(under ?parent, under ?grandparent); ?out, the table to fill when a table
results. How the keywords apply depends on what the ref stands for: a schema
when the ref, or what it names, is where a schema goes (schema-position?);
else a Path Item when either is where a Path Item goes, or the keywords are
operations; else another OpenAPI object (see merge-into)."
                      (let [(target name parent grandparent) (resolve-ref from
                                                                          (ref-of value)
                                                                          ?key
                                                                          ?parent
                                                                          ?grandparent)
                            kind (if (or (schema-position? ?key ?parent
                                                           ?grandparent)
                                         (schema-position? name parent
                                                           grandparent))
                                     :schema
                                     (or (path-item-position? ?key ?parent
                                                              ?grandparent)
                                         (path-item-position? name parent
                                                              grandparent)
                                         (accumulate [found false k (pairs value)
                                                      &until found]
                                           (= true (. operations k))))
                                     :path-item
                                     :reference)
                            siblings (collect [k v (pairs value)]
                                       (when (and (not= k "$ref")
                                                  (or (not= kind :reference)
                                                      (= k :summary)
                                                      (= k :description)))
                                         (values k
                                                 (if (data? k ?key ?parent
                                                            ?grandparent)
                                                     v
                                                     (deref from v k ?key
                                                            ?parent)))))]
                        (if (= (type target) :boolean)
                            ;; a boolean schema has no keywords to add to
                            (if (and (= kind :schema) (next siblings))
                                (doto (or ?out {})
                                  (tset :allOf (json.array [target siblings])))
                                target)
                            (or (not= (type target) :table)
                                (= target json.null))
                            target
                            (or ?out (next siblings))
                            (let [out (setmetatable (or ?out {})
                                                    (getmetatable target))
                                  entry {: out : target : kind : siblings}]
                              (table.insert pending entry)
                              (tset pending-of out entry)
                              out)
                            target))))

    (fn fill [entry]
      "Fills entry's table, once its target, when that is another one being
expanded, is filled."
      (when (not entry.done)
        (when entry.filling
          (error "circular $ref: refs with keywords next to them name each other"
                 0))
        (set entry.filling true)
        (let [target-entry (. pending-of entry.target)]
          (when target-entry
            (fill target-entry)))
        (merge-into entry.out entry.target entry.kind entry.siblings)
        (set entry.done true)))

    (set deref (fn [from value ?key ?parent ?grandparent]
                 (if (ref-of value)
                     (if (has-siblings? value)
                         (expand-ref from value ?key ?parent ?grandparent)
                         (let [expanded (resolve-ref from (ref-of value) ?key
                                                     ?parent ?grandparent)]
                           expanded))
                     (or (not= (type value) :table) (= value json.null))
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
                       out))))
    (fn [value]
      (set copies {})
      (set pending [])
      (set pending-of {})
      (let [out (deref {: root :base opts.base} value)]
        (each [_ entry (ipairs pending)]
          (fill entry))
        out))))

{: resolver}
