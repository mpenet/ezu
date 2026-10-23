# Output

[Documentation](README.md) › Output

JSON, JSON Lines and YAML responses are decoded, so `--select` and every `--output` format work on them; a JSON Lines response is an array of its lines' values. Other content (text, HTML, XML, …) is printed as received.

## Output formats

| `--output` | Prints |
|------------|--------|
| `json` | The body as indented JSON with sorted keys (the default) |
| `yaml` | The body as YAML |
| `raw` | The body exactly as received; with `--select`, the selected value: strings as they are, an array of strings, numbers or booleans one per line, objects and other arrays as JSON |
| `table` | An array of objects (or one object) as aligned columns under a header ruled off with `─`; an array of other values one per line |
| `csv` | The same rows as CSV (RFC 4180 quoting), with a header |
| `tsv` | The same rows as tab-separated values, with a header; tabs, newlines and backslashes in values written `\t`, `\n`, `\\` |
| `status` | The status code |
| `headers` | The response headers, one `name: value` per line, sorted |

Table columns are the fields a selection ending in `{a,b}` picks, in that order, else every field of the rows, sorted, aligned by the columns text takes on a terminal (two for wide East Asian characters and most emoji, none for combining marks). Objects and arrays inside a cell are written as compact JSON, and null or missing fields as empty cells. Control characters in values are shown escaped (`\x1B`) on a terminal; in a file or a pipe, csv and tsv write them as they are. For workflows, `table`, `csv` and `tsv` print the outputs as one row.

Output is coloured only when stdout is a terminal, and never when the `NO_COLOR` environment variable is set or `--no-color` is given. When a successful response has no body, `HTTP <status>` is printed on stderr instead.

A 4xx or 5xx response is printed on stderr, after an `HTTP <status>` line, and ezu exits with `4` or `5`; `--ignore-status` prints it like a success instead.

## Selecting

`--select` prints part of a JSON response:

| Syntax | Selects |
|--------|---------|
| `.key` | A field of an object |
| `[N]` | Element N of an array, from 0; `[-1]` is the last |
| `[]` | Every element of an array; the rest of the path applies to each |
| `..key` | Every field `key`, at any depth, as an array; the rest of the path applies to each |
| `{a,b}` | Fields `a` and `b` of an object, or of each object of an array |
| `[?PATH OP VALUE]` | The elements of an array whose PATH compares to VALUE; the rest of the path applies to each |
| `[?PATH]` | The elements of an array where PATH is present and not null or false |

In a filter, OP is `==`, `!=`, `<`, `<=`, `>` or `>=`. PATH is a field or a dotted path into the element (`tags.env`). VALUE is a JSON string, number, `true`, `false` or `null`, or else a bare word, taken as a string. A missing field equals `null`. `<`, `<=`, `>` and `>=` compare two numbers or two strings and never match anything else. Filters in a row (`[?a==1][?b==2]`) narrow the same array. A malformed filter is an error.

```sh
ezu op petstore get-pet-by-id 7 --select .category.name
ezu op petstore find-pets-by-status --q.status=sold --select '[0].name'
ezu op petstore find-pets-by-status --q.status=sold --select '[].name'
ezu op petstore find-pets-by-status --q.status=sold --select '[].{id,name}'
ezu op exo list-instances --select '.instances[?state==running].{name,id}' --output=table
ezu op exo list-instances --select '..ip-address' --output=raw
```

For anything `--select` doesn't do, pipe the JSON to [jq](https://jqlang.org): output piped to another program has no colours, so `ezu op exo list-instances | jq …` works as is.

The selection is printed in the chosen `--output` format; `[]` gives an array. A path that matches nothing prints nothing (and `HTTP <status>` on stderr), and ezu exits 0.

## Streams

With `--output` json (the default), yaml or raw, some responses are printed as they arrive rather than once complete:

- An event stream (`text/event-stream`, server-sent events) prints the data of each event when the blank line ending it arrives. Comments and the other fields (`event:`, `id:`) are left out, and so is an event the stream ends before finishing.
- JSON Lines (`application/x-ndjson`, `application/jsonl`) prints each record when its line ends.
- With `--output=raw` and no `--select`, a body that declares a type other than JSON or YAML is written as it comes, so a large download isn't held in memory.

Each event or record is printed as received, one per line; with `--select`, the selection of each instead, as pretty JSON on a terminal and compact JSON otherwise. `--output=yaml` prints each as a YAML document (`---`). Text that isn't JSON is printed as it is (and left out by a selection). Other output formats, and error responses (4xx, 5xx), wait for the whole response as usual. `-v` shows the status and headers before the stream.

A request whose `Accept` includes `text/event-stream` (from the spec, or `--h.Accept=…`) may stay silent between events for as long as the server likes; otherwise ezu gives up on a peer silent for 60 seconds. `--timeout` still limits the whole exchange, so leave it out for long streams. When the program reading ezu's output goes away (`ezu … | head -1`), ezu stops with exit code 141, as on a broken pipe.

```sh
ezu http https://api.example.com/events --h.Accept=text/event-stream --select=.status
```

## Verbose output

`-v` logs, on stderr, each request (`> METHOD URL` with the query, then its headers and body) and, once the response arrives, its status, timing and headers:

```
> GET https://petstore3.swagger.io/api/v3/pet/7
> accept: application/json, application/xml
> authorization: Bearer <redacted>
HTTP 200  0.475s
content-type: application/json
...
```

Credentials are redacted: every header and query parameter whose name contains `auth`, `cookie`, `key`, `token`, `secret`, `sig` or `passw` (so `Authorization`, `X-API-Key`, `api_key`, `X-Signature`…). The scheme of an `Authorization` header stays visible (`Bearer <redacted>`).
