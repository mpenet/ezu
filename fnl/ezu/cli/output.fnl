;; ABOUTME: Terminal output for the CLI: response rendering and selection, dry-run
;; ABOUTME: and curl printing, request logging with redaction, exit codes.
(local util (require :ezu.util))
(local tls (require :ezu.tls))
(local http-mod (require :ezu.http))
(local json (require :ezu.json))
(local pretty-mod (require :ezu.pretty))
(local width (require :ezu.cli.width))

(fn redact-header [name value ?names]
  "Value safe to print for header name: credentials are masked, as are the
headers in the set ?names (lowercase)."
  (let [n (name:lower)]
    (if (or (= n "authorization") (= n "proxy-authorization"))
        (let [(scheme) (: (tostring value) :match "^(%S+)%s")]
          (if scheme (.. scheme " <redacted>") "<redacted>"))
        (or (util.secret-name? n) (?. ?names n))
        "<redacted>"
        value)))

(fn sensitive-names [names]
  "Set of the lowercased names authentication marked on a request."
  (collect [_ n (ipairs (or names []))]
    (n:lower)
    true))

(fn sorted-headers [headers]
  (let [names (icollect [k (pairs (or headers {}))]
                k)]
    (table.sort names)
    (icollect [_ k (ipairs names)]
      [k (tostring (. headers k))])))

(fn log [text]
  "Write a line to stderr, its control characters escaped: the text comes
from specs and servers."
  (io.stderr:write (.. (util.printable text) "\n")))

(fn timing-text [t]
  "How long the phases of an exchange took, from libcurl's timings (seconds
since its start): the redirects before it, dns, tcp, tls, server (until the
first byte), download and total; phases that took no time (a reused
connection's) are left out."
  (let [phases [[:redirects (or t.redirects 0)]
                [:dns t.namelookup]
                [:tcp (- t.connect t.namelookup)]
                [:tls (if (> t.appconnect 0) (- t.appconnect t.connect) 0)]
                [:server (- t.starttransfer t.pretransfer)]
                ;; the last exchange's own time: total counts the redirects
                [:download (- t.total (or t.redirects 0) t.starttransfer)]]
        parts (icollect [_ [name seconds] (ipairs phases)]
                ;; less than half a millisecond shows as 0ms: noise
                (when (>= seconds 0.0005)
                  (.. name " " (util.duration seconds))))]
    (table.insert parts (.. "total " (util.duration t.total)))
    (table.concat parts " · ")))

(fn exchange-url [req]
  "The URL a request went to, its secret query parameters redacted."
  (util.redact-url (util.append-query (or req.url "?") (or req.query {})
                                      req.query-styles)
                   req.sensitive-query))

(fn wrap-log-timing [http-fn]
  "http-fn logging a line per exchange: method, URL, status and timing."
  (fn [req]
    (let [resp (http-fn req)]
      (when (and resp resp.timings)
        (log (.. (or req.method "?") " " (exchange-url req) "  "
                 (tostring resp.status) "  " (timing-text resp.timings))))
      resp)))

(fn wrap-log-request [http-fn]
  (fn [req]
    (log (.. "> " (or req.method "?") " " (exchange-url req)))
    (when req.body
      (log (.. "> body: " (if (= (type req.body) :table)
                              (json.encode req.body)
                              (tostring req.body)))))
    (each [_ [k v] (ipairs (sorted-headers req.headers))]
      (log (.. "> " k ": "
               (tostring (redact-header k v
                                        (sensitive-names req.sensitive-headers))))))
    (let [resp (http-fn req)
          asked (util.append-query (or req.url "") (or req.query {})
                                   req.query-styles)]
      (when (and resp resp.timings)
        (log (.. "< " (tostring resp.status) "  " (timing-text resp.timings))))
      ;; redirects are followed below: say where the answer came from
      (when (and resp resp.url (not= resp.url asked))
        (log (.. "< redirected to "
                 (util.redact-url resp.url req.sensitive-query))))
      resp)))

(fn op? [v]
  (and (= (type v) :table) (not= nil (. v :has-body))))

(fn list-ops [c]
  (let [ops []]
    (each [k v (pairs c)]
      (when (op? v)
        (table.insert ops {:k k :summary (. v :summary)})))
    (table.sort ops (fn [a b] (< a.k b.k)))
    (let [width (accumulate [w 0 _ op (ipairs ops)]
                  (math.max w (length op.k)))]
      (each [_ op (ipairs ops)]
        (print (util.printable (if op.summary
                                   (string.format (.. "%-" width "s  %s") op.k
                                                  op.summary)
                                   op.k)))))))

(fn container? [v]
  "Whether a path can go into v: an array or object, not null."
  (and (= (type v) :table) (not= v json.null)))

(fn pick-fields [value fields]
  "value with only fields kept: an object, or each object of an array."
  (let [pick (fn [obj]
               (collect [_ f (ipairs fields)] f (. obj f)))]
    (when (container? value)
      (if (or (json.array? value) (= (type (. value 1)) :table))
          (json.array (icollect [_ obj (ipairs value)]
                        (when (= (type obj) :table) (pick obj))))
          (pick value)))))

(fn filter-end [path]
  "Index of the ] closing the filter at the start of path, quotes skipped."
  (var quoted false)
  (var escaped false)
  (var close nil)
  (for [i 3 (length path) &until close]
    (let [c (path:sub i i)]
      (if escaped (set escaped false)
          (and quoted (= c "\\")) (set escaped true)
          (= c "\"") (set quoted (not quoted))
          (and (not quoted) (= c "]")) (set close i))))
  close)

(local comparisons
       {"==" #(= $1 $2)
        "!=" #(not= $1 $2)
        "<" #(and (= (type $1) (type $2)) (< $1 $2))
        "<=" #(and (= (type $1) (type $2)) (<= $1 $2))
        ">" #(and (= (type $1) (type $2)) (> $1 $2))
        ">=" #(and (= (type $1) (type $2)) (>= $1 $2))})

(fn filter-value [raw fail]
  "A filter's value: JSON (a quoted string, number, true, false, null), else
the text itself."
  (let [(ok v) (pcall json.decode raw true)]
    (if (and ok (or (not= (type v) :table) (= v json.null))) v
        ;; a quoted string, array or object that isn't JSON, or a mistyped
        ;; operator
        (raw:match "^[\"%[{=<>!]") (fail) (= raw "") (fail) raw)))

(fn parse-filter [path select-path]
  "(keep rest) for the [?PATH OP VALUE] or [?PATH] at the start of path: keep
says whether an element matches."
  (let [close (filter-end path)
        fail #(error (.. "--select: invalid filter in " path) 0)
        _ (when (not close) (fail))
        condition (path:sub 3 (- close 1))
        (lhs op rhs) (condition:match "^%s*(.-)%s*([=!<>]=?)%s*(.-)%s*$")
        field (or lhs (condition:match "^%s*(.-)%s*$"))
        compare (when op (or (. comparisons op) (fail)))
        rest (path:sub (+ close 1))]
    ;; a field is a name or a dotted path, never a search (..)
    (when (not (and (field:match "^%.?[%w_%-]+[%w_%-%.]*$")
                    (not (field:find ".." 1 true)) (not (field:find "%.$"))
                    (or (= rest "") (rest:match "^[%.%[{]"))))
      (fail))
    (values (if compare
                (let [value (filter-value rhs fail)
                      ;; operands of a type that can't be ordered never match
                      orderable #(let [t (type $)]
                                   (or (= t :number) (= t :string)))]
                  #(let [found (select-path $ field) ;; a missing field is null
                         v (if (= nil found) json.null found)]
                     (if (or (= op "==") (= op "!=")) (compare v value)
                         (and (orderable v) (orderable value) (compare v value)))))
                #(let [v (select-path $ field)]
                   (and (not= nil v) (not= json.null v) (not= false v))))
            rest)))

(fn find-fields [data name found]
  "found with every value of field name in data appended, at any depth:
depth first, in array order and key order."
  (when (container? data)
    (if (json.array? data)
        (each [_ v (ipairs data)]
          (find-fields v name found))
        (let [keys (icollect [k (pairs data)] k)]
          (table.sort keys #(< (tostring $1) (tostring $2)))
          (each [_ k (ipairs keys)]
            (when (= k name)
              (table.insert found (. data k)))
            (find-fields (. data k) name found)))))
  found)

(fn select-path [data path]
  "Value at path in data: .field, [N] (0-based, negative from the end), []
to map the rest of the path over an array, ..field for the field at any
depth (then map the rest over what is found), [?PATH OP VALUE] to keep the
elements that match (then map the rest over them), {a,b} to keep fields.
nil when the path doesn't match."
  (if (or (= nil data) (= path "")) data (path:match "^%.%.[^%.%[{]")
      (let [(name rest) (path:match "^%.%.([^%.%[{]+)(.*)$")]
        (json.array (icollect [_ v (ipairs (find-fields data name []))]
                      (select-path v rest)))) (path:match "^%.")
      (select-path data (path:sub 2)) (path:match "^%[%?")
      (let [(keep rest) (parse-filter path select-path)]
        (when (and (container? data)
                   (or (json.array? data) (= nil (next data))))
          (let [kept (json.array (icollect [_ v (ipairs data)]
                                   (when (keep v) v)))]
            ;; filters in a row narrow the same array
            (if (rest:match "^%[%?") (select-path kept rest)
                (json.array (icollect [_ v (ipairs kept)]
                              (select-path v rest)))))))
      (path:match "^%[%]")
      (when (container? data)
        (json.array (icollect [_ v (ipairs data)] (select-path v (path:sub 3)))))
      (path:match "^%[%-?%d+%]")
      (let [(index rest) (path:match "^%[(%-?%d+)%](.*)$")
            n (tonumber index)]
        (when (container? data)
          (select-path (. data (if (< n 0) (+ (length data) n 1) (+ n 1))) rest)))
      (path:match "^{")
      (let [(fields rest) (path:match "^{([^}]+)}(.*)$")]
        (when (and fields (container? data))
          (let [picked (pick-fields data
                                    (icollect [f (fields:gmatch "[^,]+")]
                                      (f:match "^%s*(.-)%s*$")))]
            (if (and (= (type (. picked 1)) :table) (not= rest ""))
                (json.array (icollect [_ obj (ipairs picked)]
                              (select-path obj rest)))
                (select-path picked rest)))))
      (let [(key rest) (path:match "^([^%.%[{]+)(.*)$")]
        (when (and key (container? data))
          (select-path (. data key) rest)))))

(fn check-select [path]
  "Raise for a malformed filter anywhere in path, or a .. without a field
name, before anything is sent."
  (var rest path)
  ;; path without its filters, whose values may hold anything
  (var outside "")
  (var at (path:find "[?" 1 true))
  (while at
    (set outside (.. outside (rest:sub 1 (- at 1))))
    (let [(_ after) (parse-filter (rest:sub at) select-path)]
      (set rest after)
      (set at (rest:find "[?" 1 true))))
  (set outside (.. outside rest))
  (when (or (outside:find "%.%.%.") (outside:find "%.%.$")
            (outside:find "%.%.[^%w_%-]"))
    (error "--select: .. must be followed by a field name, as in ..id" 0)))

(fn request-text [req]
  "Human-readable request, credentials redacted."
  (let [(url payload headers) (http-mod.encode-request req)
        lines [(.. req.method " " (util.redact-url url req.sensitive-query))]]
    (each [_ [k v] (ipairs (sorted-headers headers))]
      (table.insert lines
                    (.. k ": "
                        (redact-header k v
                                       (sensitive-names req.sensitive-headers)))))
    (when payload
      (table.insert lines "")
      (table.insert lines payload))
    (table.concat lines "\n")))

(fn curl-command [req]
  "Runnable curl command reproducing the request."
  (let [(url payload headers) (http-mod.encode-request req)
        parts ["curl" "-X" req.method (util.shell-quote url)]]
    ;; inside '...' only newlines and tabs stay as they are on a terminal
    (assert (not (and payload (payload:find "[%z\1-\8\11-\31\127]")))
            "--curl cannot inline a body with control characters (binary, CR line ends…); use --dry-run to inspect it")
    (each [_ [k v] (ipairs (sorted-headers headers))]
      (table.insert parts "-H")
      (table.insert parts (util.shell-quote (.. k ": " v))))
    (when payload
      (table.insert parts "--data-raw")
      (table.insert parts (util.shell-quote payload)))
    ;; the TLS options and timeout ezu would use
    (let [ssl (or req.ssl {})]
      (when (tls.verify-off? ssl.verify) (table.insert parts "-k"))
      (each [_ [option flag] (ipairs [[:cafile "--cacert"]
                                      [:capath "--capath"]
                                      [:certificate "--cert"]
                                      [:key "--key"]])]
        (when (. ssl option)
          (table.insert parts flag)
          (table.insert parts (util.shell-quote (. ssl option))))))
    (when req.timeout
      (table.insert parts "--max-time")
      (table.insert parts (tostring req.timeout)))
    (table.concat parts " ")))

(fn printing-transport [render]
  "Transport that prints each request instead of sending it."
  (fn [req]
    (print (util.printable (render req)))
    {:status 0 :headers {} :dry-run true}))

(fn render [v fmt use-color]
  "Render a decoded value as yaml or (default) json."
  (if (= fmt :yaml)
      (let [s (pretty-mod.yaml v 0 use-color)]
        (if (s:match "^\n") (s:sub 2) s))
      (pretty-mod.pretty v 0 use-color)))

(fn header-lines [headers ?redact]
  "Headers as sorted \"name: value\" lines; ?redact masks credentials."
  (table.concat (icollect [_ [k v] (ipairs (sorted-headers headers))]
                  (util.printable (.. k ": "
                                      (if ?redact
                                          (tostring (redact-header k v))
                                          v)))) "\n"))

(fn cell-text [v]
  "A value as table cell text: nothing for null, compact JSON for objects and
arrays."
  (if (or (= nil v) (= json.null v)) ""
      (= (type v) :string) v
      (json.encode v)))

(fn csv-field [text]
  (if (text:find "[,\"\r\n]")
      (.. "\"" (pick-values 1 (text:gsub "\"" "\"\"")) "\"")
      text))

(fn tsv-field [text]
  (pick-values 1
               (text:gsub "[\\\t\n\r]"
                          {"\\" "\\\\" "\t" "\\t" "\n" "\\n" "\r" "\\r"})))

(fn aligned [rows]
  "rows of cells as columns padded to their widest cell, two spaces apart,
the first row (the header) ruled off from the others."
  (let [widths []]
    (each [_ row (ipairs rows)]
      (each [i cell (ipairs row)]
        (tset widths i (math.max (or (. widths i) 0) (width.of cell)))))
    (table.insert rows 2 (icollect [_ w (ipairs widths)]
                           (string.rep "─" w)))
    (table.concat (icollect [_ row (ipairs rows)]
                    (let [line (table.concat (icollect [i cell (ipairs row)]
                                               (.. cell
                                                   (string.rep " "
                                                               (- (. widths i)
                                                                  (width.of cell)))))
                                             "  ")]
                      (pick-values 1 (line:gsub "%s+$" ""))))
                  "\n")))

(local table-fields
       {:csv csv-field
        :tsv tsv-field
        ;; a cell stays on its line, its control characters off
        ;; the terminal
        :table #(util.printable (tsv-field $))})

(fn tabulate [value fmt ?columns]
  "value as table, csv or tsv text, or nil for nothing: the objects of an
array (or one object) are a row each, under a header of ?columns or of every
key, sorted; an array of other values is one per line."
  (let [field (. table-fields fmt)
        rows (if (or (json.array? value)
                     (and (container? value) (= nil (next value))))
                 value
                 [value])
        objects (icollect [_ row (ipairs rows)]
                  (when (and (container? row) (not (json.array? row)))
                    row))]
    (if (= value json.null) nil (and (= nil (next objects)) (next rows))
        (table.concat (icollect [_ row (ipairs rows)]
                        (field (cell-text row))) "\n")
        (and (= nil (next objects)) (not ?columns)) nil
        (let [columns (or ?columns
                          (let [seen {}]
                            (each [_ obj (ipairs objects)]
                              (each [k (pairs obj)]
                                (tset seen k true)))
                            (doto (icollect [k (pairs seen)] k)
                              (table.sort))))
              lines [(icollect [_ c (ipairs columns)]
                       (field c))]]
          (each [_ obj (ipairs objects)]
            (table.insert lines
                          (icollect [_ c (ipairs columns)]
                            (field (cell-text (. obj c))))))
          (if (= nil (. columns 1)) nil (= fmt :table) (aligned lines)
              (table.concat (icollect [_ cells (ipairs lines)]
                              (table.concat cells (if (= fmt :csv) "," "\t")))
                            "\n"))))))

(fn selected-fields [?select]
  "The fields a selection ending in {a,b} picks, in its order."
  (let [picked (when ?select
                 (?select:match "{([^}]*)}%s*$"))]
    (when picked
      (icollect [f (picked:gmatch "[^,]+")]
        (f:match "^%s*(.-)%s*$")))))

(fn raw-text [v]
  "A selection as raw text: strings as they are, a list of values one per
line, objects as JSON."
  (if (not= (type v) :table) (tostring v)
      ;; nothing to print, rather than an empty line
      (and (json.array? v) (= nil (. v 1))) nil
      (and (json.array? v) (accumulate [all true _ x (ipairs v) &until (not all)]
                             (not (container? x))))
      (table.concat (icollect [_ x (ipairs v)]
                      (if (= x json.null) "null" (tostring x)))
                    "\n") (render v :json false)))

(fn format-output [resp output use-color ?select ?terminal]
  "Text to print for a successful response, or nil when there is nothing to
show. ?terminal: stdout is a terminal, whose control characters csv and tsv
values mustn't reach (they stay as they are in files and pipes)."
  (let [body (if (and ?select resp.body) (select-path resp.body ?select)
                 resp.body)]
    (match (or output :json)
      :status (tostring resp.status)
      :headers (header-lines resp.headers)
      :raw (if ?select
               (when (not= nil body)
                 (raw-text body))
               (when (and resp.raw (> (length resp.raw) 0))
                 resp.raw))
      (where (or :table :csv :tsv)) (let [text (when (not= nil body)
                                                 (tabulate body output
                                                           (selected-fields ?select)))]
                                      (if (and text ?terminal)
                                          (util.printable text)
                                          text))
      fmt (when (not= nil body) (render body fmt use-color)))))

(fn exit-code [status ignore-status]
  "Process exit code for an HTTP status: 4 for 4xx, 5 for 5xx, else 0."
  (if (or ignore-status (< status 400)) 0
      (< status 500) 4
      5))

(fn print-http-resp [resp
                     output
                     no-color
                     verbose
                     ?select
                     ?elapsed
                     ?ignore-status]
  (let [error? (and resp.status (>= resp.status 400) (not ?ignore-status))
        use-color (not no-color)
        timing (if ?elapsed (string.format "  %.3fs" ?elapsed) "")]
    (when resp.next-page-status
      (io.stderr:write (string.format "warning: stopped after %d page(s): next page returned HTTP %s\n"
                                      resp.pages resp.next-page-status)))
    ;; a stream showed them before its body
    (when (and (or verbose error?) (not resp.streamed))
      (io.stderr:write (.. "HTTP " resp.status timing "\n"))
      (when verbose
        (io.stderr:write (.. (header-lines resp.headers true) "\n\n"))))
    (if error?
        (do
          (when (not= nil resp.body)
            (if (= (type resp.body) :string)
                (log resp.body)
                ;; coloured when stderr, not just stdout, is a terminal
                (io.stderr:write (.. (render resp.body :json
                                             (and use-color (util.terminal? 2)))
                                     "\n"))))
          (exit-code resp.status false))
        (let [text (when (not resp.streamed)
                     (format-output resp output use-color ?select
                                    (util.terminal? 1)))]
          (if text (print text) ;; a streamed body was printed as it came
              (not (or verbose resp.streamed))
              (io.stderr:write (.. "HTTP " resp.status "\n")))
          0))))

(fn print-resp [resp output no-color verbose ?select ?elapsed ?ignore-status]
  "Print a response; returns the process exit code."
  (if resp.dry-run 0
      (print-http-resp resp output no-color verbose ?select ?elapsed
                       ?ignore-status)))

(fn strip-location [msg]
  "Remove Lua error location prefixes (file.lua:N: or [string \"chunk\"]:N:)."
  (let [(s) (: (tostring msg) :gsub "[^%s:]+%.lua:%d+: " "")
        (s) (s:gsub "%[string \"[^\"]*\"%]:%d+: " "")]
    s))

(local exit-mt {:__tostring #$.message})

(fn exit [code ?message]
  "Stop the current command with an exit code; run prints ?message to stderr."
  (error (setmetatable {:code code :message (or ?message "")} exit-mt) 0))

(fn exit-status [err]
  "(code message) for an error raised while running a command."
  (if (= (getmetatable err) exit-mt)
      (values err.code err.message)
      (values 1 (strip-location (tostring err)))))

(fn die [msg]
  (exit 1 (strip-location (tostring msg))))

(fn exit? [err]
  "Whether err is a command's exit (see exit)."
  (= (getmetatable err) exit-mt))

;; ---- streams ----

;; a line longer than this is not a stream ezu can print
(local max-line (* 16 1024 1024))

(fn line-reader [on-line on-end]
  "A consumer of text cut into lines ended by CRLF, LF or CR: on-line gets
each line as it ends, on-end what is left when the text ends. A CR ending a
piece may be the first half of a CRLF."
  (var parts [])
  (var size 0)
  (var after-cr false)

  (fn add [text]
    (when (> (length text) 0)
      (table.insert parts text)
      (set size (+ size (length text)))
      (when (> size max-line)
        (error "a line of the stream is longer than 16 MB" 0))))

  (fn finish []
    (let [line (table.concat parts)]
      (set parts [])
      (set size 0)
      (on-line line)))

  (fn [chunk]
    (if (= nil chunk)
        (on-end (table.concat parts))
        (let [chunk (if (and after-cr (= (chunk:sub 1 1) "\n")) (chunk:sub 2)
                        chunk)]
          (set after-cr false)
          (var from 1)
          (var at (chunk:find "[\r\n]" from))
          (while at
            (add (chunk:sub from (- at 1)))
            (finish)
            (when (= (chunk:sub at at) "\r")
              (if (= at (length chunk)) (set after-cr true)
                  (= (chunk:sub (+ at 1) (+ at 1)) "\n") (set at (+ at 1))))
            (set from (+ at 1))
            (set at (chunk:find "[\r\n]" from)))
          (add (chunk:sub from))))))

(fn event-stream [on-data]
  "A consumer of an event stream (text/event-stream, as WHATWG defines it):
on-data gets the data of each event, its data lines joined, at the blank line
ending it. Other fields and comments are left out, and so is an event the
stream ends before."
  (var data [])
  (var first true)
  (line-reader (fn [line]
                 (let [line (if first
                                (pick-values 1 (line:gsub "^\239\187\191" ""))
                                line)
                       (field value) (if (line:find ":" 1 true)
                                         (line:match "^([^:]*):(.*)$")
                                         (values line ""))]
                   (set first false)
                   (if (= line "")
                       (when (next data)
                         (on-data (table.concat data "\n"))
                         (set data []))
                       (= field "data")
                       (table.insert data (pick-values 1 (value:gsub "^ " ""))))))
               #nil))

(fn json-lines [on-record]
  "A consumer of JSON Lines: on-record gets each line that isn't blank."
  (let [record #(when ($:match "%S") (on-record $))]
    (line-reader record record)))

(fn write-out [text]
  "text on stdout, flushed: a reader that went away ends the command, with
the code a SIGPIPE would give (ezu ignores the signal)."
  (when (not (and (io.stdout:write text) (io.stdout:flush)))
    (exit 141)))

(fn stream-printer [output use-color ?select terminal verbose]
  "A req.stream that prints successful responses as they arrive, for output
json (the default), yaml or raw: the events of an event stream and the
records of JSON Lines one by one, ?select applied to each (as received
without a selection, pretty JSON on a terminal), and with output raw and no
selection any body that isn't JSON or YAML as it comes. Other responses are
left to print-resp."
  (let [render-value (fn [v]
                       (if (= output :raw) (raw-text v)
                           (= output :yaml) (.. "---\n"
                                                (render v :yaml use-color))
                           terminal (render v :json use-color)
                           (json.encode v)))
        record (fn [text]
                 (let [(json? decoded) (pcall json.decode text true)
                       v (if (and json? ?select) (select-path decoded ?select)
                             json? decoded)]
                   (if (and json? (not ?select) (= output :raw))
                       (write-out (.. text "\n"))
                       (not json?)
                       (when (not ?select) (write-out (.. text "\n")))
                       (and (not ?select) (not terminal) (not= output :yaml))
                       ;; as received: numbers keep their digits
                       (write-out (.. (pick-values 1 (text:gsub "\n" " ")) "\n"))
                       (not= nil v)
                       (write-out (.. (render-value v) "\n")))))
        show-head (fn [status headers]
                    (when verbose
                      (io.stderr:write (.. "HTTP " status "\n"
                                           (header-lines headers true) "\n\n"))))]
    (fn [status headers]
      (when (and (util.success? status)
                 (or (= nil output) (= output :json) (= output :yaml)
                     (= output :raw)))
        (let [content-type (util.header headers "content-type")
              lower (: (or content-type "") :lower)
              consumer (if (lower:match "^%s*text/event%-stream")
                           (event-stream record)
                           (http-mod.json-lines-type? lower)
                           (json-lines record)
                           ;; only what needs no reading: JSON stays whole
                           ;; (pages merged), a selection reads the body
                           (and (= output :raw) (not ?select) content-type
                                (not (http-mod.json-type? lower))
                                (not (http-mod.yaml-type? lower)))
                           #(when $ (write-out $)))]
          (when consumer
            (show-head status headers))
          consumer)))))

(fn executed-steps [result]
  "Step ids in the order they first ran."
  (let [seen {}]
    (icollect [_ id (ipairs result.step-order)]
      (when (not (. seen id))
        (tset seen id true)
        id))))

(fn show-value [v]
  (if (= v "") "\"\"" (tostring v)))

(fn format-servers [servers selected vars]
  "Servers with their variables; * marks the selected server, and each
variable shows the value in effect."
  (let [lines []]
    (each [i s (ipairs servers)]
      (table.insert lines
                    (.. (if (= i selected) "* " "  ") i ". " s.url
                        (if s.description (.. " — " s.description) "")))
      (let [names (icollect [name (pairs s.variables)] name)]
        (table.sort names)
        (each [_ name (ipairs names)]
          (let [v (. s.variables name)
                value (let [given (. vars name)]
                        (if (not= nil given) given v.default))]
            (table.insert lines (.. "       " name " = " (show-value value)
                                    "  (default: " (show-value v.default)
                                    (if v.enum
                                        (.. "; one of: "
                                            (table.concat (icollect [_ e (ipairs v.enum)]
                                                            (show-value e))
                                                          ", "))
                                        "")
                                    ")"))))))
    (table.concat lines "\n")))

(fn print-step [raw-step-id step render full]
  (local step-id (util.printable raw-step-id))
  (if full
      (do
        (print (.. "--- " step-id " request ---"))
        (when step.op-ref
          (print (.. "operation: " (util.printable (tostring step.op-ref)))))
        (when (and step.request step.request.body)
          (print (render step.request.body)))
        (print (.. "--- " step-id " response"
                   (if (and step.response step.response.status)
                       (.. " HTTP " step.response.status)
                       "") " ---")))
      (print (.. "--- " step-id " ---")))
  (when step.response (print (render step.response.body))))

(fn only-list [outputs]
  "The value of outputs' one output when it is an array, else nil."
  (let [(k v) (next outputs)]
    (when (and k (= nil (next outputs k)) (json.array? v))
      v)))

(fn print-arazzo-result [result mode output no-color ?select ?terminal]
  "Print a workflow's result as mode says, its outputs in the output format,
?select picking in them as for responses. As a table (csv, tsv), outputs
that are one list are a row per item."
  (let [render #(if (. table-fields output) (tabulate $ output)
                    (render $ output (not no-color)))
        outputs (or result.outputs {})
        shown (if (and (. table-fields output) (not ?select))
                  (or (only-list outputs) outputs)
                  outputs)
        print-outputs #(match (format-output {:body shown
                                              :status 200
                                              :headers {}}
                                             output (not no-color) ?select
                                             ?terminal)
                         text (print text))]
    (match (or mode :final)
      ;; progress already went to stderr while the workflow ran
      (where (or :final :progress))
      (when (next outputs)
        (print-outputs))
      (where (or :steps :full))
      (do
        (each [_ step-id (ipairs (executed-steps result))]
          (print-step step-id (. result.steps step-id) render (= mode :full)))
        (when (next outputs)
          (print "--- outputs ---")
          (print-outputs))))))

{: redact-header
 : wrap-log-request
 : wrap-log-timing
 : timing-text
 : op?
 : list-ops
 : select-path
 : check-select
 : sorted-headers
 : request-text
 : curl-command
 : printing-transport
 : render
 : header-lines
 : format-output
 : exit-code
 : print-http-resp
 : print-resp
 : strip-location
 : die
 : exit
 : exit-status
 : executed-steps
 : show-value
 : format-servers
 : print-arazzo-result
 : stream-printer
 : exit?}
