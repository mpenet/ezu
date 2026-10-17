# Requests

[Documentation](README.md) › Requests

How ezu builds a request from the command line, checks it against the spec, and sends it.

## Path parameters

Path parameters are positional, in the order they appear in the path, and sent exactly as typed (percent-encoded). `--help` shows them.

```sh
ezu op petstore get-pet-by-id 7
```

## Query parameters and headers

```sh
ezu op petstore find-pets-by-status --q.status=available
ezu op myapi list-items --q.tag=a --q.tag=b --h.X-Request-Id=42
```

A profile's `query` and `headers` are added to every request; values given on the command line win.

## Body

```sh
# inline JSON (or YAML)
ezu op myapi add-pet -d '{"name": "Rex", "status": "available"}'

# from a file
ezu op myapi add-pet -d @pet.json

# from stdin
cat pet.json | ezu op myapi add-pet -d @-

# field by field
ezu op myapi add-pet --b.name=Rex --b.status=available --b.age=3

# nested fields
ezu op myapi create-vm --b.instance-type.id=abc123 --b.disk.size=10
```

`--b.` fields are merged: `--b.a.b=1 --b.a.c=2` gives `{"a": {"b": 1, "c": 2}}`. With `-d` as well, the fields are merged over its object.

Field values take their type from the request schema: a `string` property keeps `007` as `"007"`, `integer` and `number` properties become numbers, `boolean` takes `true` or `false`, an `array` property takes one item per field, typed by its `items` schema (`--b.tags=a --b.tags=b` gives `["a", "b"]`) or a whole JSON array (`--b.tags='["a","b"]'`), and an `object` property takes JSON. A field the schema doesn't describe follows JSON's rules: `42`, `-1.5`, `true` and `false` become numbers and booleans, anything else stays a string.

How `-d` is read depends on the operation's request content type:

- JSON, form (`application/x-www-form-urlencoded`) and `multipart/form-data` operations take JSON or YAML.
- Any other type (`application/octet-stream`, `text/plain`, XML, images…) is sent byte for byte: `ezu op myapi upload-image -d @photo.png`.

For `multipart/form-data`, a field whose value starts with `@` becomes a file part, named after the file: `--b.file=@photo.png`. Write `@@` for a value that starts with a literal `@`.

JSON bodies are encoded with object keys in sorted order, integers exactly and decimals in their shortest exact form, so the same command always sends the same bytes.

## Checks before sending

Before sending, ezu compares the request with the operation's description:

- A required query parameter or header that is missing is an error naming the option to add (`--q.status=…`). Headers count wherever they come from: `--h.`, the profile, or authentication.
- A query parameter the operation doesn't declare (often a typo) prints a warning listing the declared ones; the request is still sent.
- A JSON body is checked against the request schema: required properties, types, `enum`, nested objects and arrays, `additionalProperties: false`, lengths, ranges and item counts, `allOf`, `anyOf` and `oneOf`. Errors name the exact place, such as `body.disks[0].size: expected integer, got string`. `pattern` and `format` are not checked.

All problems are reported together and nothing is sent. `--no-validate` sends anyway, for specs stricter or looser than the API they describe.

## Checking responses

`--check-response` checks the response against the spec: its status must be one the operation declares (itself, its range like `4XX`, or `default`), its content type one declared for that status, and its body must match the schema, as a response: read-only properties may be required, write-only ones aren't. The response is printed as usual; the differences follow on stderr, and ezu exits 1 (or the status's own code, 4 or 5):

```console
$ ezu op exo get-instance 9b1e… --check-response
…
! response.state: "migrating" is not one of starting, running, stopped
! response.public-ip: expected string, got null
```

It tells API users where an API strays from its spec, and API authors where their spec or their API needs fixing.

## Retries

Responses with status 408, 429, 500, 502, 503 or 504, and network errors, are retried up to `--retry` times (default 2), for GET, HEAD and OPTIONS requests only unless `--retry-unsafe` is given. ezu waits as long as the response's `Retry-After` header asks, at most `--retry-max-wait` seconds, and otherwise 1, 2, 4… seconds. An authentication failure is never retried.

## Waiting for a state

`--until` sends the request again, every `--every` seconds (default 5), until a condition holds, then prints the last response. It saves writing a loop, or a workflow, for an operation that takes a while:

```sh
ezu op exo get-operation 5f2c… --until "\$response.body#/state == 'success'"
ezu op exo get-instance 9b1e… --until "\$response.body#/state == 'running'" --every 2
ezu op exo get-instance 9b1e… --until '$statusCode == 404'   # until it is deleted
```

The condition is written as in [workflows](arazzo.md#success-criteria), about the request and its response: `$statusCode`, `$response.body#/pointer`, `$response.header.NAME`, `$method`, `$url` and `$request…`, compared with `==`, `!=`, `<`… and combined with `&&` and `||`. It is checked before anything is sent: a condition that can't be evaluated, or that refers to anything else, stops ezu at once. When it holds, ezu exits 0, whatever the status. Each response is read whole to be checked, events and JSON Lines included, and the last one is printed.

On a terminal, a line says how many requests were sent and what the condition found. ezu stops trying when another request would start after `--max-time` seconds (default 600), with exit code 1, saying why, for example `($response.body#/state is "failure")`. `--every` must be more than 0. As with [retries](#retries), a POST or PATCH is only sent again with `--retry-unsafe`; `--until` can't be used with `--dry-run` or `--curl`, which send nothing.

## Pagination

When a GET response is a JSON array and has a `Link: <…>; rel="next"` header, ezu follows the links and prints all items as one array. Every page is requested with the same headers and credentials; a link to another origin (scheme, host or port) is not followed. ezu stops after `--max-pages` pages (default 25). If a later page fails, the items collected so far are printed with a warning naming the failing status. `--no-paginate` prints the first page as it is.

## Dry runs

`--dry-run` prints the request that would be sent, without sending it or authenticating: the header authentication would add shows as `<redacted>`. `--curl` prints a runnable `curl` command instead; it does authenticate, and its output contains the credentials.
