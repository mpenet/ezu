# Commands

[Documentation](README.md) › Commands

Every command of `ezu` and its options. What the options do is detailed in [Requests](requests.md) and [Output](output.md).

```
ezu op <profile-or-schema> [operation] [path-params...] [options]
ezu az <name-or-file> [workflow-id] [path-params...] [options]
ezu http [METHOD] <url-or-path> [options]
ezu mcp <profile-or-schema> [--allow-writes] [--arazzo NAME] [options]
ezu profile list
ezu profile show <name>
ezu profile import-restish [file] [--dry-run]
ezu auth <profile> [--logout]
ezu completion <fish|bash|zsh>
ezu --version
ezu --licenses
```

| Command | Description |
|---------|-------------|
| `op` | Call an operation. The first argument is a profile name, or a spec's URL or file path (JSON or YAML). Without an operation, lists the operations. |
| `az` | Run an [Arazzo workflow](arazzo.md) (`arazzo` is an alias). Without a workflow id, lists the workflows. |
| `http` | Sends a request to any URL, without a spec; see [Requests without a spec](#requests-without-a-spec-http). |
| `mcp` | Serves the API's operations, and Arazzo workflows, as tools to AI agents (MCP over stdio); see [MCP server](mcp.md). |
| `profile list` | Profiles with the schema each one uses, inherited ones included. |
| `profile show` | A profile as ezu uses it, `extends` resolved. |
| `profile import-restish` | Adds the APIs of a Restish configuration as profiles; see [Moving from Restish](restish.md). |
| `auth` | Authenticates a profile now: for static credentials and external tools, prints the headers that would be sent (and a query API key, or the signing command); for OAuth, runs the flow again. `--logout` deletes the cached token. |
| `completion` | Prints the completion script for a shell; see [Shell completion](install.md#shell-completion). |
| `--version` | Prints ezu's version and the libcurl and TLS library builds it uses. |
| `--licenses` | Prints the licenses of the software the binary contains (also in [THIRD-PARTY.md](../THIRD-PARTY.md)). |

## Operation names

Operation names are the spec's `operationId`s in lowercase, dash-separated words: `getPetById` → `get-pet-by-id`, `projects/list_cards` → `projects-list-cards`. An operation without `operationId` is named after its method and path: `GET /pets/{petId}` → `get-pets-pet-id`. When two operationIds would get the same name, the first by path keeps it and the other is named after its method and path.

## Options

Options go anywhere after the command. `--name=value` and `--name value` are equivalent, except for the field options (`--q.`, `--h.`, `--b.`, `--server.`, `--ssl.`), which take `NAME=VALUE` as one argument. `--` ends the options: everything after it is positional (for a path parameter starting with `-`). An unknown option, or one that doesn't apply to the command (`--profile` on `op`, `--select` on `az`), is an error.

## Operations (`op`)

| Option | Description |
|--------|-------------|
| `--list` | List the operations with their summaries |
| `--help` | Show an operation's documentation (or list the operations) |
| `-d VALUE`, `--body=VALUE` | Request body: JSON or YAML inline, `@file`, or `@-` for stdin; see [Body](requests.md#body) |
| `--b.KEY=VAL`, `--body.KEY=VAL` | One body field; dotted keys build nested objects (`--b.disk.size=10`) |
| `--q.KEY=VAL`, `--query.KEY=VAL` | Query parameter; repeating a key sends a list (`--q.tag=a --q.tag=b`) |
| `--h.KEY=VAL`, `--header.KEY=VAL` | Request header; repeating a name joins the values with `, ` |
| `--select=PATH` | Print only part of the response; see [Selecting](output.md#selecting) |
| `--output=FORMAT` | `json` (default), `yaml`, `raw`, `table`, `csv`, `tsv`, `status` or `headers` (anything else is an error); see [Output formats](output.md#output-formats) |
| `--no-color` | Never colour the output (colours are only used on a terminal anyway) |
| `-v`, `--verbose` | Log the request and the response status and headers on stderr |
| `--timing` | Log a line per request on stderr: method, URL, status, and how long each phase took (`dns 3ms · tcp 17ms · tls 25ms · server 75ms · download 5ms · total 126ms`, after `redirects …` when redirects led there); phases a reused connection skips are left out. `-v` shows the same timings |
| `--check-response` | Report on stderr how the response differs from the spec, and exit 1 if it does; see [Checking responses](requests.md#checking-responses) |
| `--until=CONDITION` | Send the request again until CONDITION holds, then print the last response; see [Waiting for a state](requests.md#waiting-for-a-state) |
| `--every=N`, `--max-time=N` | With `--until`: seconds between requests (default 5), and how long to keep trying (default 600) |
| `--dry-run` | Print the request instead of sending it; credentials redacted |
| `--curl` | Print an equivalent `curl` command instead of sending (credentials included) |
| `--no-validate` | Send even when the request doesn't match the spec; see [Checks](requests.md#checks-before-sending) |
| `--ignore-status` | Treat 4xx and 5xx responses as successes: print the body on stdout, exit 0 |
| `--timeout=N` | Give up on a request after N seconds |
| `--retry=N` | Retries for 408, 429, 500, 502, 503 and 504 responses and network errors (default 2); see [Retries](requests.md#retries) |
| `--retry-unsafe` | Also retry POST, PUT, PATCH and DELETE |
| `--retry-max-wait=N` | Longest wait between retries, in seconds (default 300) |
| `--max-pages=N` | Most pages to follow; see [Pagination](requests.md#pagination) (default 25) |
| `--no-paginate` | Return the first page only |
| `--base-url=URL` | Send requests to URL instead of the spec's server |
| `--servers` | List the spec's servers and their variables; see [Servers](configuration.md#servers) |
| `--server-index=N` | Use the spec's Nth server (default 1) |
| `--server.NAME=VAL` | Set a server URL variable |
| `--ssl.KEY=VAL` | TLS option: `cafile`, `capath`, `certificate`, `key`, `verify` (`--ssl.verify=none` skips verification) |
| `--reload` | Fetch the spec again instead of using the cache |
| `--cache-ttl=N` | How long a fetched spec stays cached, in seconds (default 3600) |

## Workflows (`az`)

`az` takes `--help`, `--output`, `--no-color`, `-v`, `--no-validate`, `--timeout`, the retry options, `--base-url`, `--server-index`, `--server.` and `--ssl.` as above. And:

| Option | Description |
|--------|-------------|
| `NAME=VALUE` | A workflow input, typed from its schema; see [Inputs](arazzo.md#inputs) |
| `--inputs=VALUE` | All inputs as a JSON or YAML object, inline or `@file` |
| `--profile=NAME` | Profile to authenticate with |
| `--arazzo-output=MODE` | `final` (default), `steps`, `progress` or `full`; see [Output modes](arazzo.md#output-modes) |
| `--max-gotos=N` | Most jumps to a single step before the workflow aborts (default 50) |
| `--trust-sources` | Load Arazzo sources from anywhere, not only next to the document; see [Workflows of other documents](arazzo.md#workflows-of-other-documents) |
| `--check` | Check the document, or one workflow, against its sources without running it; see [Checking a document](arazzo.md#checking-a-document) |
| `--link` | Print how to make a named document a command of its own; see [A document as its own command](arazzo.md#a-document-as-its-own-command) |

`--dry-run` and `--curl` are refused: later steps depend on real responses. Use `-v` to log every request.

## Requests without a spec (`http`)

```sh
ezu http https://api.example.com/health
ezu http GET /zones --profile exo
ezu http POST /instances --profile exo --b.name=web1 --b.disk.size=10
ezu http DELETE https://api.example.com/items/7 --profile ex -v
```

The method defaults to `GET`. A path (`/zones`) is appended to the API's URL: `--base-url`, else the profile's `base-url`, else its spec's server (with `--server-index` and `--server.`). A full URL is sent as is; with `--profile`, it must be on the profile's API origin. ezu refuses to send the profile's credentials anywhere else.

`http` goes through the same profile headers and query, authentication, retries, pagination, redirects, output and exit codes as `op`. It skips the spec-driven parts: operation names, parameter and body checks, and `--help` per operation. Its body is sent as given: `-d` with JSON is sent as JSON, with `Content-Type: application/json`; anything else goes as is, with the content type you set with `--h.Content-Type=…`. `--b.` fields build a JSON object, on top of `-d`'s JSON or YAML object if one is given.

`http` takes `--profile=NAME` and the `op` options above except `--list`, `--servers`, `--no-validate`, `--reload` and `--cache-ttl`.

## MCP server (`mcp`)

| Option | Description |
|--------|-------------|
| `--allow-writes` | Offer every operation, not only GET, HEAD and OPTIONS |
| `--arazzo=NAME` | Also offer the workflows of an Arazzo context or file |

`mcp` also takes `-v`, `--timeout`, the retry options, `--max-pages`, `--no-paginate`, `--base-url`, `--server-index`, `--server.`, `--ssl.`, `--reload` and `--cache-ttl` as above.

## Others

| Option | Commands | Description |
|--------|----------|-------------|
| `--logout` | `auth` | Delete the profile's cached token |
| `--timeout`, `--ssl.KEY=VAL` | `auth` | Also apply to `auth`'s requests to the token endpoint |
| `--dry-run` | `profile import-restish` | Show the profiles that would be added |

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success, including any response with `--ignore-status` |
| 1 | Anything else that went wrong: bad arguments, a request that fails the checks, a network or TLS error, an authentication failure, a failed workflow |
| 4 | The API answered with a 4xx status |
| 5 | The API answered with a 5xx status |
