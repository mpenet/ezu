# Changelog

All notable changes to ezu, named atlas until 1.0.0-beta7. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **Workflow inputs are `name=value` arguments** (`ezu az vm create name=web1 size=medium`), typed from the inputs schema; `-i`, `--i.`/`--input.`, and `-d`/`--b.` for workflows are gone (they say so). Arguments starting with `-` are always ezu's options and `name=value` ones always inputs, so neither can shadow the other; an unknown input name stops with a suggestion. Positional inputs are those a workflow declares in `x-ezu-args`, no longer guessed from the path parameters of its steps. Completion offers `NAME=` and allowed values; `az --check` checks `x-ezu-args`.
- atlas is now **ezu** (絵図, a pictorial map): the command, the Lua modules (`require "ezu"`), the rock and the Homebrew formula. Configuration and cache are in `~/.config/ezu` and `~/.cache/ezu`; copy `~/.config/atlas` there to keep your profiles.

### Added

- Plugins: Lua or Fennel files listed in the configuration's `plugins` provide authentication methods, which profiles use by name. A method is a function signing each request in-process, with helpers for SHA-256, HMAC-SHA256, base64, hex, JSON and URLs; a plugin's path is absolute (or starts with `~/`), and its file and directories must belong to the user (or root, for directories) and be writable only by them. The binary carries the Fennel compiler (compressed, loaded only for a Fennel plugin), and `doc/examples/plugins/exoscale.fnl` signs Exoscale's API requests.
- Releases include `.deb` and `.rpm` packages of the Linux binaries (x86_64 and arm64), with bash, zsh and fish completion and the licenses.
- `--check-response` on `op` reports how the response differs from the spec (an undeclared status or content type, a body the schema doesn't allow, checked as a response) and exits 1 when it does.
- `ezu --licenses` prints the licenses of the software the binaries contain (Lua, libcurl, Mbed TLS, LuaSocket, lyaml, LibYAML, lunajson, Fennel, and zlib and musl on Linux, and the Unicode data); they are also in `THIRD-PARTY.md`, attached to each release.
- `ezu az FILE [WORKFLOW] --check` checks a document against its sources without running it: operations and workflows that don't exist, parameters and bodies, references to steps, outputs, inputs, workflows and components, conditions, regexes and JSONPath queries, and actions. It exits 1 on an error.
- `--until CONDITION` on `op` and `http` sends the request again, every `--every` seconds, until the condition holds (written as in workflows: `$response.body#/state == 'ready'`, `$statusCode == 404`), then prints the last response and exits 0. After `--max-time` seconds (default 600) it gives up saying what the condition found. The condition is checked before anything is sent; a POST or PATCH is only sent again with `--retry-unsafe`.
- `--timing` logs a line per request: method, URL, status and how long each phase took (dns, tcp, tls, server, download, total, and the redirects that led there). `-v` shows the same timings for each exchange, and the library's responses carry them as `:timings`.

### Fixed

- On a terminal that doesn't report its width, the lines of workflow progress were cut down to `…`; they now fit 80 columns.

## [1.0.0-beta7] - 2026-10-16

### Changed

- `--arazzo-output progress` prints a line per step once its success criteria are checked: `✓` or `✗`, its position (`2/5`), what it calls, its time and the response's status. A step polled with `goto` or `retry` stays on one `↻` line with the wait and the criterion that failed, then ends with the number of attempts and the total time; the steps of a workflow run by another one are indented. On a terminal, lines are updated in place and fit its width. Step outputs are no longer printed there; `steps` and `full` print them.
- A failed workflow says which criterion failed and the values it compared: `step 'find' failed: $statusCode == 200 ($statusCode is 404); HTTP 404 {…}`, the body shortened to 500 characters. Warnings no longer land on a step's line while it is updated in place.
- The library's `on-step` events: `:workflow` when a workflow starts, `:running`, `:done` after the step's criteria are checked (with `:passed`, `:failure` and `:error`) and `:action`; each carries the workflow, its depth, and the step's index, count and attempt.
- In an Arazzo payload, an object member whose own members all resolve to nothing (inputs that aren't given) is left out, like a single member, rather than sent empty. The payload itself, array elements and objects written as `{}` stay objects.

### Fixed

- Progress output marked a step `✓` when its response arrived, before its success criteria were checked, so a failing step showed `✓`.

## [1.0.0-beta6] - 2026-10-16

### Added

- Arazzo 1.1 documents: Selector Objects (JSONPath or JSON pointer, with runtime expressions embedded in `{}`) wherever values are evaluated; `jsonpath` criteria and Expression Type Objects; `{$expression}` in regex and JSONPath conditions; replacements with `targetSelectorType: jsonpath`; `in: querystring` parameters; action `parameters` as the inputs of the workflow an action runs; step `timeout` and `dependsOn`; `$self`, `$outputs.NAME`, `$workflows.ID.inputs.NAME` and source description fields. AsyncAPI steps and XPath are refused.
- JSONPath (RFC 9535), passing its compliance test suite, with I-Regexp (RFC 9485) patterns for `match()` and `search()`, matched in linear time.
- Operations take `:querystring`, the whole query string (OpenAPI 3.2).
- An Arazzo example that creates an Exoscale instance from names.

### Changed

- An Arazzo condition that can't be evaluated fails, with a warning on stderr saying why, instead of failing the workflow.
- Arazzo `regex` conditions are ECMAScript regular expressions, as in the specification's examples (`^2\d{2}$`), rather than Lua patterns; they run in linear time, so back-references and lookaround are refused.
- The binaries are about a quarter smaller (1.5 MB on macOS, 1.9 MB on Linux): the program is embedded as stripped Lua bytecode, the C libraries are optimized for size, and the linker drops the code nothing calls.
- An Arazzo step's `timeout` is in milliseconds, as Arazzo 1.1 defines it, rather than seconds.

### Fixed

- Ctrl-C ends the binary at once, with the usual signal status; it could be taken for an error, caught, and atlas would go on, then exit 0.

## [1.0.0-beta5] - 2026-10-16

### Added

- `atlas http [METHOD] URL-or-path`: a request without a spec, with a profile's headers, authentication and TLS settings, retries, pagination, `-v`, `--dry-run`/`--curl` and the usual output and exit codes. A path is appended to the profile's API URL; a profile's credentials are only sent to its API's origin.
- `atlas.base-url`: the URL a client of a schema sends requests to.
- Spec discovery: a profile with `base-url` and no `schema` finds its spec through the base URL's `Link` header (`service-desc`, `service-doc`, `describedby`), `openapi.json` and `openapi.yaml` under it, or the base URL itself; the location is cached. Restish profiles without `spec_files` import without a warning.
- Streamed responses: server-sent events and JSON Lines are printed record by record as they arrive (with `--select` applied to each), and with `--output=raw` and no `--select`, a body of a type other than JSON or YAML is written as it comes. Requests accepting `text/event-stream` may stay idle between events. The transport takes a `:stream` function for this.
- `--output=table` aligns wide characters (CJK, most emoji) and combining marks by their display width; csv and tsv escape control characters on a terminal.
- `--select` filters: `[?state==running]`, `[?size>10]`, `[?tags.env=="prod"]`, `[?tags]`; negative indexes (`[-1]`); `..key` for a field at any depth.
- `--output=table`, `csv` and `tsv` for arrays of objects, with the columns a `{a,b}` selection picks.
- `atlas mcp PROFILE`: an MCP server over stdio (protocol 2026-07-28, and the earlier ones that open with `initialize`). The operations become tools, authenticated with the profile: the read-only ones by default, all with `--allow-writes`, or those the profile's `mcp.operations` lists (names, or patterns like `list-*`). `--arazzo=NAME` adds the workflows of an Arazzo context as tools.
- YAML responses are decoded, and JSON Lines responses (`application/x-ndjson`, `application/jsonl`) become an array of their lines' values.

### Changed

- `--output=raw` prints a selected array of strings, numbers or booleans one value per line.
- Output escapes C1 control characters and the bidirectional overrides (U+202A–202E, U+2066–2069) as well as ASCII control characters, so text from an API can neither drive nor reorder what the terminal shows.
- The documentation is split into a page per topic, with an index in `doc/README.md`; `make test` checks its links.

### Fixed

- Content types that only start like JSON (`application/json-seq`, `application/jsonl`) are no longer decoded as JSON.
- YAML with an alias inside its own anchor, or whose aliases expand past a million nodes, is refused instead of crashing atlas or making it spin; this covers YAML specs and Arazzo documents too.
- OpenAPI 3.0 `nullable` allows null whatever else the schema says (`enum`, `allOf`…), and read-only properties declared in `allOf` members are not required in requests.
- External auth tools run with stdin from `/dev/null` (unless given the request to sign), and the browser of OAuth flows with stdin and stdout on `/dev/null`.

## [1.0.0-beta4] - 2026-10-15

### Changed

- The binaries use mbedTLS (3.6 LTS) for TLS instead of OpenSSL: about 2 MB instead of 5.5 MB. Certificate verification, client certificates (`certificate`/`key`, RSA or EC) and the CA file and directory work as before; TLS 1.0 and 1.1 are refused. The Linux binaries no longer contain OpenSSL 3.3, which is out of support; they are built on Alpine 3.24, as static position-independent executables.

## [1.0.0-beta3] - 2026-10-15

### Added

- Homebrew: `brew install mpenet/tap/atlas` (macOS and Linux, with shell completion); releases update the tap.

### Fixed

- A spec behind an auth proxy is fetched again with credentials when the first request is redirected to a sign-in page on another origin, as after a 401; `-v` shows where a redirected request ended.

## [1.0.0-beta2] - 2026-10-15

The first beta with release binaries: 1.0.0-beta1 was published without them, and its release can no longer take files. The code is that of 1.0.0-beta1: see its section of [CHANGELOG.md](https://github.com/mpenet/ezu/blob/main/CHANGELOG.md) for the changes since 1.0.0-alpha14.

### Fixed

- The release workflow publishes a release only once all its files are uploaded, and builds on Intel macOS runners.

## [1.0.0-beta1] - 2026-10-15

### Security

- **TLS certificates are now verified.** Up to and including 1.0.0-alpha14, HTTPS requests did not verify the server's certificate or host name (luasec's default), so credentials sent by atlas — bearer tokens, API keys, Basic credentials, OAuth client secrets and refresh tokens — could be intercepted by anyone able to sit between atlas and the API. Upgrade, and consider rotating credentials used over untrusted networks. Verification uses the system CA bundle (`SSL_CERT_FILE`, the usual bundle locations, `SSL_CERT_DIR`) and fails closed when none is found; `--ssl.verify=none` or a profile's `"insecure": true` opt out.
- Redirects are followed by atlas itself: GET and HEAD only, at most 5, never from `https` to `http`, and credential headers are dropped when the origin changes.
- Header names and values containing CR, LF or NUL are rejected.
- `-v` and `--dry-run` redact secret query parameters; `az` sends credentials to source schemas only after a 401/403.
- external-tool signing and query api-key auth no longer modify the caller's request table.
- Same-origin checks for redirects and pagination parse URLs as libcurl does: a crafted `Location` or `Link` such as `https://evil.example?@api.example.com/` was taken for the API's own origin, so credentials followed it to another host.
- Documents named by a spec's external `$ref`s are fetched without the profile's headers or credentials unless they are on the spec's own origin.
- The bash completion script treats the candidates it gets (operation names, enum values from the spec…) as data: `compgen -W` expanded `$(...)` in them, so a spec could run commands when completing.
- On a redirect to another origin, the headers authentication added are dropped whatever their name, and logs and dry runs redact them and a query API key whatever their name; user info in URLs is redacted too.
- The schema cache directory is private to the user (0700).
- The config file written by `profile import-restish`, its `.bak` copy and OAuth tokens are created readable by the user only (0600), with no moment when they are readable by others.
- A query API key no longer appears in the error printed when a request fails in transport.
- The profile's `headers` and credentials are not sent to a spec hosted on another origin than the profile's `base-url`.
- `--dry-run` doesn't run an external signing tool, and doesn't send placeholder credentials when fetching a spec.
- Bash completion inserts values quoted: an enum value from a spec containing spaces or shell syntax (`$(...)`) stays one argument and never runs.
- Text from a spec (summaries, descriptions, server descriptions, completion help) is printed with its control characters escaped, so a spec cannot send terminal escape sequences; so is an OAuth provider's error description.
- The OAuth callback checks the `state` before anything else: a forged callback without it can no longer pose as the provider's error.
- `-v` redacts credentials in response headers (`set-cookie`, `...token`) as it does in request headers.
- Error messages, warnings, Arazzo step ids and the OAuth device prompt escape control characters too: they quote specs and servers.
- `op` fetches the documents a spec's `$ref`s name like the spec itself: through the same transport (so `-v` shows them), with the profile's headers and credentials only when the spec is on the API's origin; they used to get the profile's headers whatever the origin.
- `-v`, `--dry-run`, `--curl`, logged response headers and text error bodies escape control characters too.
- A same-origin redirect keeps a query API key; another origin still never gets it.
- A query API key is read when a request is sent, so an unset `env:` variable no longer breaks `--list`, `--help`, `--servers` or `--dry-run`; a spec answering 401 is fetched again with the query key or signature, as with header credentials; `-v` logs spec fetches too.
- Headers added by external-tool signing are marked as credentials: logs and dry runs redact them, and they are dropped on a redirect to another origin.
- The libcurl binding rejects URLs, header names and values and options that contain a NUL byte, rather than cutting them short.
- A URL whose host part holds a backslash or a control character (such as a NUL in a `$ref`) matches no origin, so credentials never follow it (libcurl reads `http://a\@b/` as host `b`); retried schema fetches and next-page requests keep the marking of credential headers, so a later cross-origin redirect drops them; `$ref` errors redact the document's URL.

### Added

- HTTP goes through libcurl: proxies from `https_proxy`/`http_proxy`/`all_proxy`/`no_proxy`, connection reuse, transparent gzip, per-request timeouts.
- `atlas --version`, also reporting the libcurl/OpenSSL build; `atlas.version` in the library.
- `atlas profile import-restish [FILE] [--dry-run]` imports Restish configs (v1 `apis.json`, v2 `restish.json`) as profiles.
- Profiles take `query` (parameters on every request) and `tls.ca_cert`.
- `az WORKFLOW --help` documents a workflow's inputs and steps.
- `--servers`, `--server-index` and `--server.NAME=VAL` to list and choose servers; `atlas.servers` and `atlas.server-url` in the library.
- Short field prefixes `--q.`, `--h.`, `--b.`, `--i.`.
- Request checks before sending: missing required parameters and invalid JSON bodies are errors, undeclared query names warn; `--no-validate` sends anyway.
- Shell completion of operations, parameters, body fields, enum values, server variables, Arazzo contexts, workflows and inputs.
- Operations without `operationId` are available under a name made of their method and path (`GET /pets/{petId}` → `get-pets-pet-id`); every operation exposes `:name`.
- `atlas.json` (`decode`, `encode`, `array`, `array?`): JSON that keeps empty arrays apart from empty objects; use `json.array` to send an empty array from a body built in Lua.
- `atlas.parse-schema` parses fetched schema text, rejecting documents that are not a mapping.
- Release binaries for macOS x86_64 and Linux arm64, a `SHA256SUMS` file and build provenance attestations.

### Changed

- **Breaking (library):** operations take a request table, `op.invoke {:path :query :headers :body :timeout}`; positional calls remain a shorthand.
- **Breaking (library):** `atlas.load-schema` and the `:load-schema` client option take `{:ssl :headers}` instead of positional arguments.
- **Breaking (library):** the operation field `:has-body?` is now `:has-body`; `:n-path` is gone (use `(length op.path-params)`).
- **Breaking (library):** every `$ref` to the same place resolves to the same table, so recursive schemas are cyclic tables (`node.properties.next` is `node`) instead of being cut to `{}`. Code that walks `op.spec` or `op.body-schema` must not assume a tree, and should not serialise them as is. This makes resolution linear for any spec (it was exponential on heavily recursive ones such as Stripe's) and lets validation check recursive data at every depth.
- **Breaking (library):** JSON `null` is `json.null` (from `atlas.json`) in decoded response bodies, both in arrays and as object members, so a body shows and re-encodes as received; it used to drop members and corrupt arrays (`[1,null,3]` came out as `{"1":1,"3":3}`). Code testing `(= nil body.x)` for a null `x` must test `(= json.null body.x)`.
- **Breaking:** an option that doesn't apply to the command is an error: `op --profile p` used to send the request without the profile, `az --select` was ignored.
- **Breaking:** Arazzo runs fail when a source description cannot be loaded, and a plain `operationId` defined by several sources is an error; qualify it as `$sourceDescriptions.NAME.ID`.
- Operation names are lowercase words joined by dashes whatever the operationId's style: `projects/list-cards`, `get_folders_id#get_shared_link` and `bookmarks-(-deprecated)` become `projects-list-cards`, `get-folders-id-get-shared-link` and `bookmarks-deprecated`. When two operationIds yield the same name, the first by path keeps it and the others are named after their method and path, the same way on every run.
- Query parameters are serialized in their declared `style` and `explode` (`form`, `spaceDelimited`, `pipeDelimited`, `deepObject`); array path parameters use the `simple` style.
- Arazzo: string comparisons in conditions are case-insensitive and `''` escapes a quote, as the spec says; a backslash is now an ordinary character. A misspelled expression (`$statuscode`) is an error rather than `null`, and payload text that merely starts with `$` is kept as is.
- Arazzo: a request that fails in transport is a step failure, so `onFailure` and `retry` handle it; `retry` runs the step named by `stepId` first; a response's `Retry-After` overrules `retryAfter`; `requestBody.contentType` and `replacements` are supported; `$request.query.NAME` and `$request.path.NAME` work.
- `--output` and `--arazzo-output` reject unknown values.
- Building a client is linear in the size of the spec: Stripe's went from not finishing to 0.07 s, Kubernetes' from 1 s to 0.01 s.
- The `ssl` options are `cafile`, `capath`, `certificate`, `key` and `verify`; other luasec options are no longer used.
- The macOS binaries run on macOS 12 or later: Lua, OpenSSL (3.5 LTS) and libyaml are built from pinned sources for that target, where the previous ones only started on the macOS version of the machine that built them.
- The binaries link OpenSSL, libyaml, zlib and libcurl statically. The Linux binaries are fully static, built against musl: they run on any distribution (the previous ones needed glibc 2.34 or later, libssl 3 and libyaml).
- YAML is read with YAML 1.2 core schema semantics; mapping keys keep their source text.
- `$ref` resolution handles JSON Pointer escapes, references into other files and URLs, and path items; an unresolved reference is an error.
- Authentication happens only when a request is sent, never for `--help`, `--list`, `--servers` or `--dry-run`.

### Fixed

- Base URLs ending in `/` no longer produce `//` in request paths.
- A schema URL answering with an HTML page is reported as such instead of being read as a file path.
- Empty JSON arrays came out as `{}`: printed that way, and re-sent that way, so `-d '{"tags":[]}'` sent `{"tags":{}}`. Arrays now stay arrays, empty or not, through decoding, printing, YAML, validation and encoding; validation also stopped treating an empty object as an array.
- JSON request bodies are encoded exactly and the same way every time: integers above 2^53 (IDs) are no longer rounded, floats are written in their shortest exact form (`0.1`, not `0.10000000000000001`), and object keys are sorted, so `--dry-run` and `--curl` output is reproducible.
- Arazzo: workflow inputs take the `default` their schema declares when not given (help already showed it).
- Arazzo: `$steps.ID.outputs.pet.name` (and the same for `$inputs` and `$workflows`) silently meant `outputs.pet`; names may contain dots, so it now names the output `pet.name`, and when there is none but there is a `pet`, the error points to the JSON pointer form `$steps.ID.outputs.pet#/name`.
- `atlas profile list` shows the schema a profile inherits through `extends`, and keeps listing past a profile whose `extends` is broken.
- Completion resolves `extends`; a child profile's header overrides its parent's whatever the case; `false` in a profile overrides `true` in the configuration.
- Arrays inside Arazzo payloads and `--select` results stay arrays when empty.
- A `$ref`'d path item whose schemas are recursive no longer overflows the stack.
- Validation accepts OpenAPI 3.1 boolean schemas, applies `nullable` only with a `type`, and tells empty arrays from empty objects.
- The request content type is chosen the same way on every run (JSON first), and no `Content-Type` is sent without a body.
- Help shows 3.1 type arrays (`string | null`); YAML output quotes control characters and writes infinities as `.inf`.
- Number fields accept only JSON numbers (no hex), and an integer too large for 64 bits stays text instead of being rounded.
- `--server-index=0`, `--b.=1` and similar mistakes give clear errors instead of crashing; error responses with a text body are printed as they are.
- Colours are only used when stdout is a terminal, and never when `NO_COLOR` is set: piping `atlas` into `jq` or a file gave escape codes.
- YAML documents could be misread or rejected at random ("control characters are not allowed") when the garbage collector freed the text while libyaml was still reading it.
- An operationId defined twice (Cloudflare has one) no longer hides one of the two operations.
- `--output yaml` quotes a key named `<<` instead of writing a merge key.
- `--select` no longer crashes when picking fields (`{a,b}`) from a scalar or from an array mixing objects and scalars.
- Help lists body properties and responses in a stable order.
- Arazzo sub-workflow steps honour success criteria, actions and outputs; `dependsOn` runs first; cycles are detected.
- `json.null` is read-only: Arazzo `replacements` wrote into it, changing every null at once.
- Coercion of `--q.`/`--b.` values and help handle OpenAPI 3.1 boolean schemas and type arrays (`["integer", "null"]`).
- Arazzo templates render a null as empty text and objects as JSON; `$find` skips null and scalar elements.
- Null members of query and form objects are left out instead of being sent as `null`.
- Completion offers only the options a command takes (`--dry-run` is not offered for `az`); the zsh script also works when autoloaded from `fpath`.
- `--servers` checks `--server.NAME=VAL` against the server's variables and their allowed values, as requests do.
- Path items written as `$ref`s (`paths: {/x: {$ref: paths/x.yaml}}`) share the schemas they refer to like inline ones do, so building such a client is linear again.
- Specification extensions (`x-...`) holding a non-object value in `paths` or `responses` no longer crash building the client, and help leaves them out.
- Help, completion and workflow input defaults handle OpenAPI 3.1 boolean schemas (`schema: true`).
- External-tool signing serializes the query in its declared style (`deepObject`…), as unsigned requests do.
- Arazzo checks `--server.NAME=VAL` against the variables of the server chosen with `--server-index`, not always the first one.
- A path parameter of `.` or `..` is percent-encoded, so it can no longer change the request's path.
- A local spec whose server URL is root-relative (`/v1`) gives the documented "no base-url" error.
- `$ref` inside example data (`example`, `examples.*.value`, `default`, `enum`, `const`) is kept as data instead of being resolved.
- Arazzo `operationPath` fragments may be percent-encoded (`~1pets~1%7BpetId%7D`).
- A timeout under a millisecond no longer means no timeout.
- `az --profile` with an unknown profile is an error instead of running without it.
- `$ref` inside a JSON Schema `examples` array is data too, while a property called `value` of a schema called `examples` still resolves; a `$ref` to a JSON `null` gives `null`.
- Arazzo: `$sourceDescriptions.NAME.ID` keeps a dotted operationId (`storage.buckets.list`) whole; sources without a `type` are loaded as OpenAPI; a replacement target may append to an array with `-`; a response's `Retry-After` (seconds or a date) waits at most `--retry-max-wait` seconds (300 by default).
- `enum` accepts object and array values equal to one of its entries.
- `atlas.parse-schema` rejects `null` and arrays; an empty item in a `parameters` list is ignored.
- An Example pulled in by a `$ref` to a whole file keeps its `value` as data.
- Nested objects and arrays in query, form and path values are an error instead of being sent as `table: 0x…`.
- `servers` declared on a path item or an operation are used for it, unless `:base-url` is given.
- Query parameters declared with JSON `content` are sent as JSON text (`--q.filter='{"a":1}'` in the CLI).
- An operationId with no ASCII letters or digits is named after its method and path instead of the empty name.
- Media types are matched whatever their case (`Application/JSON`).
- Arazzo: a misspelled part of an expression (`$response.bdy`, `$response.body.status`, `$steps.s.output`) is an error instead of `null` or the whole body.
- A spec without `servers` has one at `/`, as OpenAPI says: a spec served by the API itself (FastAPI's `/openapi.json`) works without `--base-url`.
- Validation doesn't require `readOnly` properties in request bodies.
- Header and cookie values that are arrays are sent in the simple style (`a,b`); objects are an error instead of `table: 0x…`.
- Servers declared by an operation follow `:server-index`/`--server-index`, and `:server-vars` may set their variables.
- Relative URLs (next-page links, `$ref`s) keep their query, fragment, trailing slash and empty segments as written; only `.` and `..` segments are resolved.
- Pagination and redirects of requests with JSON query parameters no longer fail.
- Arazzo accepts server variables that only an operation's or path item's servers declare.
- `--server-index` on a spec without `servers` reports 0 servers.
- Help names an operation by the name the client gave it, also when its operationId's name was taken.
- Validation lets names matching `patternProperties` through `additionalProperties: false`, and ignores `required: true` (a Swagger 2 leftover) instead of crashing; so do help and completion.
- Network-path references (`//host/path`) in `$ref`s and server URLs keep the spec's scheme only.
- Pagination leaves alone a body that merely starts with `[` and ends with `]` without being one JSON array.
- Timeouts and TLS options reach every fetch: Arazzo documents and the documents they refer to, OAuth token requests, and completion's (5 seconds).
- `atlas auth` keeps the cached token until a new one is obtained.
- `--curl` includes the TLS options (`-k`, `--cacert`, `--cert`, `--key`) and `--max-time`.
- A body (`-d`, `--b.`) for an operation that takes none is an error instead of being dropped.
- Bash completion inserts values containing `:` or `=` correctly (`de:fra-1`, URLs).
- An external signing tool that fails (non-zero exit, output that isn't a JSON object) stops the request instead of letting it go out unsigned; so does a bearer-token tool that fails.
- `atlas auth` reads a query API key's `env:` value, and takes `--timeout`.
- The CLI validates bodies and attaches multipart files whatever the case of the media type; completion follows `--server-index N` as well as `--server-index=N`.
- A config, `profiles` or `arazzo` section, Arazzo context (`file`, `inputs`), profile, `extends` target or profile `schema` of the wrong type is reported clearly; a repeated JSON query parameter is an error.
- A required query parameter that the profile's `query` or a query API key provides is not reported missing.
- An authentication failure while sending (a signing tool or a query key's `env:` variable) is not retried; the OAuth device flow stops on a token error other than `authorization_pending`/`slow_down`, with the provider's description, instead of polling until it times out.
- `--curl` refuses a body with control characters (CR line ends, binary) instead of printing a command that sends something else.
- A profile missing a parameter its auth method needs (`token_url`, `commandline`…) is reported as such when authenticating; it can still be listed, shown, completed and logged out of. `env:` values are read only where used, so a valid cached token works without them, and every OAuth parameter (URLs, `scope`, `audience`) and the signing command take `env:`.
- `api-key` auth takes `"in": "cookie"`; a location other than `header`, `query` or `cookie` is an error instead of being sent as a header.
- `profile import-restish` uses Restish's callback (`redirect_url`, else `http://localhost:8484/`) for authorization-code logins, and warns about a basic login without password, `auth_method` and `redirect_scheme`; external-tool `"omitbody": "false"` keeps the body.
- The OAuth device flow keeps polling when a provider answers "pending" with HTTP 200.
- A cookie API key joins the cookies a request already sends instead of being left out; the device flow sends `client_secret` when one is set; Restish imports keep a profile's own `redirect_port` and `redirect_path` (and port 80 for a `redirect_url` without one).
- A query API key whose name holds `-`, `[` or spaces is no longer added twice (or crashing) on a redirect.
- A request atlas can't build (a line break in a header, nested query values) fails at once instead of being retried, also with request signing.
- A cookie API key counts as given only when the request sends a cookie of its name (not any cookie), also when fetching a spec after a 401; repeated `--h.Cookie` values are joined with `; `.
- Bash completion no longer inserts `''` after `--NAME=`.
- `profile import-restish` warns about a profile's `url_overrides` and an IPv6 `redirect_url`.
- Multipart arrays are sent one part per element (several files under one name) instead of as one JSON part; a declared media type range (`*/*`) comes after concrete types and sends JSON instead of `Content-Type: */*`.
- Completion expands `~/` in spec and workflow paths.
- A document that isn't an OpenAPI spec (an API's JSON answer, a config file) is reported as such instead of giving an empty listing.
- Pagination works over a custom `http-fn` that returns only the decoded `:body`.
- A cached OAuth token is used only with the token endpoint and client that issued it: after changing a profile's auth, a new token is obtained instead of sending the old one (tokens cached by earlier versions are obtained again once).
- A profile without `schema` is reported as such instead of being read as a file path; `--b.` fields on an array `-d` body are an error; colours go to stderr only when it is a terminal.
- Profiles whose `auth`, `headers`, `query`, `ssl`, `tls`, `server` or `retry` is not an object, or whose `auth` has no `name`, are errors instead of being ignored (a string `auth` sent requests unauthenticated); so are unknown `--ssl.` options and a `--timeout` of 0 or less. Malformed Restish configs and workflows without a string `workflowId` give clear messages.
- Completion lists the operations of specs whose `$ref`s point into other files.
- `atlas auth` shows a query API key and the signing command, which it printed nothing for; `atlas completion` rejects options.
- `--timeout` (and a profile's `timeout`) applies to fetching specs and the documents their `$ref`s name: a server that never answers no longer hangs atlas.
- Completion works in bash 3.2 (macOS), after variable assignments (`FOO=1 atlas …`) and, in zsh, after other commands on the line (`true && atlas …`); it uses the profile's `cache-ttl` and TLS settings and gives up on a spec fetch after 5 seconds.
- An OAuth token response without `access_token` is reported as such.
- `--b..=1`, `-i .=1`, non-object `--inputs`/`-d` for workflows, `atlas profile` and `atlas profile show` without a name give clear errors.
- Many more; see the commit history.

## [1.0.0-alpha14] - 2026-07-06

Earlier releases are described on the [releases page](https://github.com/mpenet/ezu/releases).

[1.0.0-beta7]: https://github.com/mpenet/ezu/compare/v1.0.0-beta6...v1.0.0-beta7
[1.0.0-beta6]: https://github.com/mpenet/ezu/compare/v1.0.0-beta5...v1.0.0-beta6
[1.0.0-beta5]: https://github.com/mpenet/ezu/compare/v1.0.0-beta4...v1.0.0-beta5
[1.0.0-beta4]: https://github.com/mpenet/ezu/compare/v1.0.0-beta3...v1.0.0-beta4
[1.0.0-beta3]: https://github.com/mpenet/ezu/compare/v1.0.0-beta2...v1.0.0-beta3
[1.0.0-beta2]: https://github.com/mpenet/ezu/compare/v1.0.0-beta1...v1.0.0-beta2
[1.0.0-beta1]: https://github.com/mpenet/ezu/compare/v1.0.0-alpha14...v1.0.0-beta1
[1.0.0-alpha14]: https://github.com/mpenet/ezu/releases/tag/v1.0.0-alpha14
