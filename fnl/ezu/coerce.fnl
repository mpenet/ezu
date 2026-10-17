;; ABOUTME: Converts command-line string values into typed values,
;; ABOUTME: guided by a JSON Schema when one is known.
(local json (require :ezu.json))

(fn json-number [s]
  "The number s writes, if it is a JSON number literal (no leading zeros, hex,
etc.) that Lua holds exactly: an integer beyond 64 bits or a number beyond
the floating-point range gives nil."
  (when (or (s:match "^%-?0$") (s:match "^%-?0[%.eE]") (s:match "^%-?[1-9]"))
    (when (and (s:match "^%-?%d+%.?%d*[eE]?[%+%-]?%d*$") (not (s:match "%.$"))
               (not (s:match "%.[eE]")) (not (s:match "[eE][%+%-]?$")))
      (let [n (tonumber s)
            integer-literal? (s:match "^%-?%d+$")]
        (when (and n (not= n math.huge) (not= n (- math.huge))
                   (or (not integer-literal?) (= (math.type n) :integer)))
          n)))))

(fn decode-json [s]
  (let [(ok v) (pcall json.decode s)]
    (if (and ok (not= v nil)) v s)))

(fn type-of [?schema]
  "The type ?schema asks for, or nil: a 3.1 boolean schema says nothing
about it, and of a 3.1 list of types, the one that isn't null decides."
  (let [t (when (= (type ?schema) :table) ?schema.type)]
    (if (= (type t) :table)
        (accumulate [found nil _ x (ipairs t) &until found]
          (when (not= x "null") x))
        t)))

(fn from-string [s ?schema]
  "Convert s to the type ?schema asks for; without a schema, JSON numbers
and true/false are converted and everything else stays a string."
  (match (type-of ?schema)
    "string" s
    "integer" (or (math.tointeger (json-number s)) s)
    "number" (or (json-number s) s)
    "boolean" (if (= s "true") true
                  (= s "false") false
                  s)
    "array" (decode-json s)
    "object" (decode-json s)
    _ (if (= s "true") true
          (= s "false") false
          (or (json-number s) s))))

(fn schema-at [schema keys]
  "Schema of the property reached by following keys through object properties."
  (accumulate [cur schema _ k (ipairs keys) &until (= cur nil)]
    (when (= (type cur) :table)
      (?. cur :properties k))))

{: from-string : schema-at : type-of}
