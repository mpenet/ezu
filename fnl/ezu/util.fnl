;; ABOUTME: Shared helpers: JSON pointers, URL/form encoding, path templating,
;; ABOUTME: URL resolution, header lookup, secrets and ezu directories.
(local json (require :ezu.json))
(fn unescape-pointer [segment]
  "A JSON Pointer segment with ~1 and ~0 unescaped (in that order)."
  (pick-values 1 (-> segment (: :gsub "~1" "/") (: :gsub "~0" "~"))))

(fn success? [status]
  "True for 2xx HTTP statuses."
  (and (= (type status) :number) (>= status 200) (< status 300)))

(fn json-pointer [obj ptr]
  "Value at JSON Pointer ptr (RFC 6901) in obj: \"\" is obj itself, ~1 and ~0
are unescaped, numeric segments index arrays 0-based."
  (accumulate [cur obj seg (ptr:gmatch "/([^/]*)")]
    (when (= (type cur) :table)
      (let [key (unescape-pointer seg)
            n (when (key:match "^%d+$") (tonumber key))]
        (if (and n (= nil (. cur key)))
            (. cur (+ n 1))
            (. cur key))))))

(fn camel->kebab [s]
  (let [(s) (s:gsub "(%u+)(%u%l)" "%1-%2")
        (s) (s:gsub "(%l)(%u)" "%1-%2")]
    (s:lower)))

(fn operation-name [method path op-spec]
  "Name of an operation: its operationId, or its method and path when it has
none (get /pets/{petId} → get-pets-pet-id), in lowercase words joined by
dashes (getPetById → get-pet-by-id, projects/list_cards → projects-list-cards)."
  (let [words (if op-spec.operationId
                  (camel->kebab (tostring op-spec.operationId))
                  (table.concat (icollect [word (path:gmatch "%w+")]
                                  (camel->kebab word))
                                "-"))
        name (if op-spec.operationId words (.. (method:lower) "-" words))]
    (pick-values 1 (: (: (name:lower) :gsub "[^%w]+" "-") :gsub "^%-*(.-)%-*$"
                      "%1"))))

(fn extract-path-params [template]
  (icollect [p (template:gmatch "{([^}]+)}")] p))

(fn xdg-dir [env-var fallback]
  (let [base (os.getenv env-var)]
    (.. (if (and base (not= base ""))
            base
            (.. (or (os.getenv "HOME") ".") "/" fallback)) "/ezu")))

(fn cache-dir []
  "Ezu cache directory: $XDG_CACHE_HOME/ezu, default ~/.cache/ezu."
  (xdg-dir "XDG_CACHE_HOME" ".cache"))

(fn config-dir []
  "Ezu config directory: $XDG_CONFIG_HOME/ezu, default ~/.config/ezu."
  (xdg-dir "XDG_CONFIG_HOME" ".config"))

(fn replace-all [s needle replacement]
  "Replace every literal occurrence of needle in s."
  (let [out []]
    (var pos 1)
    (var i (s:find needle pos true))
    (while i
      (table.insert out (s:sub pos (- i 1)))
      (table.insert out replacement)
      (set pos (+ i (length needle)))
      (set i (s:find needle pos true)))
    (table.insert out (s:sub pos))
    (table.concat out)))

(fn shell-quote [s]
  "Quote s as a single POSIX shell word."
  (.. "'" (pick-values 1 (: (tostring s) :gsub "'" "'\\''")) "'"))

(fn printable [s]
  "s with control characters other than newline and tab written as \\xHH, so
that text from a spec can't drive the terminal (escape sequences); C1
controls and the overrides that reorder text on screen as \\u{HHHH}."
  (let [ascii (pick-values 1
                           (s:gsub "%c"
                                   (fn [c]
                                     (when (and (not= c "\n") (not= c "\t"))
                                       (string.format "\\x%02X" (string.byte c))))))
        code #(string.format "\\u{%04X}" (utf8.codepoint $))]
    ;; U+0080-009F; U+202A-202E and U+2066-2069 (bidirectional overrides)
    (accumulate [text ascii _ pattern (ipairs ["\194[\128-\159]"
                                               "\226\128[\170-\174]"
                                               "\226\129[\166-\169]"])]
      (pick-values 1 (text:gsub pattern code)))))

(fn terminal? [fd]
  "Whether file descriptor fd (1 stdout, 2 stderr) is a terminal."
  (= true (os.execute (.. "test -t " fd))))

(fn edit-distance [a b]
  "The number of one-character insertions, deletions or substitutions that
turn a into b (Levenshtein)."
  (var previous (fcollect [j 0 (length b)] j))
  (for [i 1 (length a)]
    (let [row [i]]
      (for [j 1 (length b)]
        (table.insert row
                      (math.min (+ 1 (. previous (+ j 1))) (+ 1 (. row j))
                                (+ (. previous j)
                                   (if (= (a:sub i i) (b:sub j j)) 0 1)))))
      (set previous row)))
  (. previous (+ (length b) 1)))

(fn closest [name candidates]
  "The candidate closest to name, when close enough to be a likely typo."
  (let [limit (math.max 2 (math.floor (/ (length name) 3)))]
    (accumulate [best nil _ c (ipairs candidates)]
      (let [d (edit-distance name c)]
        (if (and (<= d limit) (or (= best nil) (< d (edit-distance name best))))
            c
            best)))))

(fn duration [seconds]
  "seconds for a person: 205ms, 1.50s, 12.3s, 2m03s."
  (if (< seconds 1)
      (string.format "%dms" (math.floor (+ (* seconds 1000) 0.5)))
      (< seconds 10)
      (string.format "%.2fs" seconds)
      (< seconds 60)
      (string.format "%.1fs" seconds)
      (string.format "%dm%02ds" (math.floor (/ seconds 60))
                     (math.floor (% seconds 60)))))

(fn terminal-columns []
  "Columns of the terminal on stderr, else $COLUMNS, else nil."
  (let [h (io.popen "stty size <&2 2>/dev/null")
        out (when h (h:read :*a))]
    (when h (h:close))
    ;; a terminal that doesn't know its size says 0
    (accumulate [found nil _ v (ipairs [(and out (out:match "^%d+ (%d+)"))
                                        (os.getenv :COLUMNS)])
                 &until found]
      (let [n (tonumber v)]
        (when (and n (> n 0)) n)))))

(fn json-content? [param]
  "Whether a parameter is declared with JSON content rather than a schema."
  (accumulate [found false media-type (pairs (or (?. param :content) {}))
               &until found]
    (not= nil (: (media-type:lower) :find "json" 1 true))))

(fn required-names [schema]
  "The property names a schema requires; required: true (a Swagger 2
leftover) or a non-table schema require none."
  (let [r (when (= (type schema) :table) schema.required)]
    (if (= (type r) :table) r [])))

(fn write-private [path text]
  "Write text to path, readable by its owner only (0600); missing parent
directories are created 0700. Returns true, or nil and an error."
  (let [dir (or (path:match "^(.*)/[^/]*$") ".")]
    ;; created private from the start: there is no moment when others can
    ;; read it
    (os.execute (.. "umask 077 && mkdir -p " (shell-quote dir) " && : >> "
                    (shell-quote path) " && chmod 600 " (shell-quote path)))
    (let [(f err) (io.open path :w)]
      (if f
          (do
            (f:write text)
            (f:close)
            true)
          (values nil err)))))

(local default-ports {:http "80" :https "443"})

(fn origin [url]
  "scheme://host:port of an http(s) URL, port explicit, as libcurl connects:
the authority ends at the first / ? #, and user info before its last @ is
dropped. nil for anything else, and for an authority holding a \\, which
URL parsers read differently: such a URL matches no origin."
  (let [(scheme rest) (url:match "^(%a[%w+.-]*)://(.*)$")
        scheme (and scheme (scheme:lower))]
    ;; control characters (a NUL ends the URL libcurl sees) match no origin
    (when (and scheme (. default-ports scheme) (not (url:find "%c")))
      (let [authority (rest:match "^([^/?#]*)")
            hostport (or (authority:match "^.*@(.*)$") authority)
            (host port) (if (hostport:match "^%[")
                            (hostport:match "^(%[[^%]]*%]):?(%d*)$")
                            (hostport:match "^([^:]*):?(%d*)$"))]
        (when (and host (not= host "") (not (authority:find "\\" 1 true)))
          (.. scheme "://" (host:lower) ":"
              (if (= port "") (. default-ports scheme) port)))))))

(fn header [headers name]
  "Case-insensitive header lookup."
  (let [wanted (name:lower)]
    (accumulate [found nil k v (pairs (or headers {})) &until found]
      (when (= (k:lower) wanted) v))))

(fn url-encode [s]
  (when (and (= (type s) :table) (not= s json.null))
    (error "nested objects and arrays can't be sent in a URL or form; send them in a JSON body"
           0))
  (pick-values 1
               (: (tostring s) :gsub "[^%w%-%.%_%~]"
                  (fn [c] (string.format "%%%02X" (string.byte c))))))

(local permanent-mt {:__tostring #$.message})

(fn permanent-error [message]
  "An error that trying again can't fix (a request that can't be built, an
authentication failure): retries pass it on at once. It reads as message."
  (setmetatable {: message :permanent true} permanent-mt))

(fn query-has? [url name]
  "Whether url's query string already has parameter name."
  (let [param (.. (url-encode name) "=")]
    (or (not= nil (url:find (.. "?" param) 1 true))
        (not= nil (url:find (.. "&" param) 1 true)))))

(fn percent-decode [s]
  "s with %XX escapes decoded; + is left as is (URI syntax)."
  (pick-values 1 (s:gsub "%%(%x%x)" (fn [h] (string.char (tonumber h 16))))))

(fn url-decode [s]
  "Decode form/query text: + is a space, then %XX escapes."
  (percent-decode (pick-values 1 (s:gsub "+" " "))))

(fn secret-name? [name]
  "True when a header or query parameter name looks like it carries a credential."
  (let [n (name:lower)]
    (not= nil (or (n:match "auth") (n:match "cookie") (n:match "key")
                  (n:match "token") (n:match "secret") (n:match "sig")
                  (n:match "passw")))))

(fn redact-url [url ?names]
  "url with its user info masked, and the values of query parameters that look
like credentials or are in the list ?names (any case), such as a request's
:sensitive-query."
  (let [(without-userinfo) (url:gsub "^(%a[%w+.-]*://)[^/?#]*@" "%1<redacted>@")
        names (collect [_ n (ipairs (or ?names []))]
                (n:lower)
                true)]
    (pick-values 1 (without-userinfo:gsub "([?&])([^=&#]+)=([^&#]*)"
                     (fn [sep name value]
                       (let [n (url-decode name)]
                         (.. sep name "="
                             (if (or (secret-name? n) (. names (n:lower)))
                                 "<redacted>"
                                 value))))))))

(fn without-nulls [v]
  "v without its null elements or members: null is no value to send."
  (if (or (not= (type v) :table) (= v json.null)) v (json.array? v)
      (icollect [_ x (ipairs v)] (when (not= x json.null) x))
      (collect [k x (pairs v)] (when (not= x json.null) (values k x)))))

(fn form-encode [params]
  "Encode params as application/x-www-form-urlencoded, keys sorted.
Array values repeat the key (OpenAPI style=form, explode=true)."
  (let [keys (icollect [k (pairs params)] k)
        parts []]
    (table.sort keys #(< (tostring $1) (tostring $2)))
    (each [_ k (ipairs keys)]
      (let [v (. params k)
            vs (if (= (type v) :table) (without-nulls v) [v])]
        (when (and (= (type v) :table) (= nil (. v 1)) (not= nil (next v)))
          (error (.. "'" (tostring k)
                     "' is an object; query and form values must be scalars or lists")
                 0))
        (each [_ x (ipairs vs)]
          (table.insert parts (.. (url-encode k) "=" (url-encode x))))))
    (table.concat parts "&")))

(local delimiters {:form "," :spaceDelimited "%20" :pipeDelimited "|"})

(fn query-pairs [name raw style explode]
  "\"key=value\" strings for one query parameter in an OpenAPI style
(form, spaceDelimited, pipeDelimited, deepObject); values are encoded,
delimiters are not."
  (let [value (without-nulls raw)
        k (url-encode name)
        enc url-encode]
    (if (not= (type value) :table) [(.. k "=" (enc value))]
        (not= nil (. value 1))
        (if explode
            (icollect [_ x (ipairs value)] (.. k "=" (enc x)))
            [(.. k "="
                 (table.concat (icollect [_ x (ipairs value)] (enc x))
                               (. delimiters style)))])
        (let [keys (doto (icollect [p (pairs value)] p)
                     (table.sort))]
          (if (= style :deepObject)
              (icollect [_ p (ipairs keys)]
                (.. k "[" (enc p) "]=" (enc (. value p))))
              explode
              (icollect [_ p (ipairs keys)]
                (.. (enc p) "=" (enc (. value p))))
              (let [d (. delimiters style)]
                [(.. k "=" (table.concat (icollect [_ p (ipairs keys)]
                                           (.. (enc p) d (enc (. value p))))
                                         d))]))))))

(fn query-string [params ?styles]
  "Query string for params, keys sorted; ?styles maps a parameter name to
its {:style :explode :json} (default: form, exploded; :json sends the value as
JSON text)."
  (let [names (doto (icollect [k (pairs params)] k)
                (table.sort #(< (tostring $1) (tostring $2))))
        parts []]
    (each [_ name (ipairs names)]
      (let [{: style : explode :json as-json} (or (?. ?styles name) {})
            style (or style :form)
            explode (if (= nil explode) (= style :form) explode)
            ;; null is no value: left out, as are null list elements
            raw (. params name)
            value (if (= raw json.null) nil (json.array? raw)
                      (icollect [_ x (ipairs raw)]
                        (when (not= x json.null) x)) raw)]
        (each [_ part (ipairs (if (= nil value) [] as-json
                                  [(.. (url-encode name) "="
                                       (url-encode (json.encode raw)))]
                                  (query-pairs name value style explode)))]
          (table.insert parts part))))
    (table.concat parts "&")))

(fn append-query [url params ?styles]
  "Append params to url as a query string (see query-string), extending any
existing one."
  (let [qs (query-string params ?styles)]
    (if (= qs "") url
        (url:find "?" 1 true) (.. url "&" qs)
        (.. url "?" qs))))

(fn normalize-segments [path]
  "Remove . and .. segments from a slash-separated path (RFC 3986): empty
segments and a trailing slash stay; .. never climbs above the root of an
absolute path."
  (let [segs (icollect [seg (: (.. path "/") :gmatch "([^/]*)/")]
               seg)
        absolute? (= (. segs 1) "")
        ;; the root's empty segment is never removed
        floor (if absolute? 1 0)
        out []]
    (each [i seg (ipairs segs)]
      (let [last? (= i (length segs))]
        (if (= seg ".") (when last? (table.insert out "")) (= seg "..")
            (do
              (if (and (> (length out) floor) (not= (. out (length out)) ".."))
                  (table.remove out)
                  (when (not absolute?) (table.insert out "..")))
              ;; a/b/.. is the directory a/
              (when last? (table.insert out "")))
            (table.insert out seg))))
    (table.concat out "/")))

(fn resolve-reference [base ref]
  "Resolve ref (URL or path) relative to the document located at base."
  (let [(origin base-path) (base:match "^(%a[%w+.-]*://[^/?#]*)([^?#]*)")]
    (if (ref:match "^%a[%w+.-]*://") ref
        ;; a network-path reference keeps only the scheme
        (and origin (ref:match "^//")) (.. (base:match "^(%a[%w+.-]*:)") ref)
        origin
        (let [dir (if (= (ref:sub 1 1) "/")
                      ""
                      (or (base-path:match "^(.*/)") "/"))
              ;; only the path has dot segments; query and fragment
              ;; are kept as they are
              (ref-path rest) (ref:match "^([^?#]*)(.*)$")]
          (.. origin (normalize-segments (.. dir ref-path)) rest))
        (= (ref:sub 1 1) "/") ref
        (normalize-segments (.. (or (base:match "^(.*/)") "") ref)))))

(fn merge-parameters [base override]
  "Concatenate OpenAPI/Arazzo parameter lists; override entries replace base entries
with the same name and location."
  (let [param-key (fn [p] (.. (tostring p.in) ":" (tostring p.name)))
        ;; an empty list item (null) declares nothing
        declared (fn [params]
                   (icollect [_ p (ipairs (or params []))]
                     (when (and (= (type p) :table) (not= p json.null))
                       p)))
        override (declared override)
        replaced (collect [_ p (ipairs override)]
                   (param-key p)
                   true)
        out (icollect [_ p (ipairs (declared base))]
              (when (not (. replaced (param-key p)))
                p))]
    (each [_ p (ipairs override)]
      (table.insert out p))
    out))

(fn simple-style [raw]
  "A path parameter value in OpenAPI's default simple style: arrays as
a,b and objects as k1,v1,k2,v2 (keys sorted), each part url-encoded."
  (local v (without-nulls raw))
  (if (not= (type v) :table) (url-encode v) (not= nil (. v 1))
      (table.concat (icollect [_ x (ipairs v)] (url-encode x)) ",")
      (let [keys (doto (icollect [k (pairs v)] k)
                   (table.sort))]
        (table.concat (icollect [_ k (ipairs keys)]
                        (.. (url-encode k) "," (url-encode (. v k))))
                      ","))))

(fn resolve-path [template params]
  "Substitute {name} segments in template with params[name], url-encoded."
  (pick-values 1 (template:gsub "{([^}]+)}"
                                (fn [param]
                                  (let [v (. params param)]
                                    (assert (and (not= nil v)
                                                 (not= v json.null))
                                            (.. "missing required path parameter: "
                                                param))
                                    (let [s (simple-style v)]
                                      ;; . and .. would be dot segments,
                                      ;; which change the path
                                      (if (or (= s ".") (= s ".."))
                                          (s:gsub "%." "%%2E")
                                          s)))))))

(fn link-params-rel [params]
  "Space-separated rel value of a Link entry's parameters, lowercased."
  (let [lower (params:lower)]
    (or (lower:match ";%s*rel%s*=%s*\"([^\"]*)\"")
        (lower:match ";%s*rel%s*=%s*([^;,%s]+)") "")))

(fn link-urls [headers rels]
  "URLs of the Link header entries with one of rels (a set of lower-case
relation names), in header order. URLs are delimited by <>, so commas
inside them are safe."
  (let [link (header headers "link")]
    (icollect [url params (: (or link "") :gmatch "<([^>]*)>([^<]*)")]
      (when (accumulate [found false rel (: (link-params-rel params) :gmatch
                                            "%S+")
                         &until found]
              (= true (. rels rel)))
        url))))

{: camel->kebab
 : link-urls
 : query-string
 : operation-name
 : extract-path-params
 : resolve-path
 : url-encode
 : url-decode
 : form-encode
 : resolve-reference
 : header
 : append-query
 : cache-dir
 : config-dir
 : merge-parameters
 : replace-all
 : shell-quote
 : write-private
 : printable
 : required-names
 : json-content?
 : terminal?
 : terminal-columns
 : duration
 : closest
 : query-has?
 : permanent-error
 : secret-name?
 : redact-url
 : origin
 : json-pointer
 : unescape-pointer
 : success?
 : percent-decode}
