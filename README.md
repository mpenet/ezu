# Ezu

<img  width="225" height="225" src="https://github.com/user-attachments/assets/4e4d83d3-4546-4af7-b8c7-cafa9bc3593b" />

A command line for any HTTP API that publishes an [OpenAPI 3](https://spec.openapis.org/oas/latest.html) description.

Point `ezu` at a spec and every operation becomes a command, with its own help, shell completion, and checks that catch mistakes before anything is sent. No code generation: the spec is read when you run the command.

- **Every operation, at your fingertips.** Path parameters as arguments, `--q.` / `--h.` / `--b.` for query, headers and body fields, typed from the spec.
- **Output you can use.** Pretty JSON or YAML, tables and CSV, `--select` to pick and filter what you need, exit codes that tell 4xx from 5xx.
- **Profiles and authentication.** Bearer, Basic, API keys, OAuth 2.0 (authorization code with PKCE, client credentials, device flow), external signing tools, mutual TLS.
- **Any URL, too.** `ezu http GET /zones --profile exo` sends a request without a spec, with the profile's authentication; a profile's credentials only go to its own API.
- **Ready for AI agents.** `ezu mcp exo` serves an API to Claude, Cursor and other [MCP](https://modelcontextprotocol.io) clients: operations become tools, authenticated with your profile, read-only unless you allow more.
- **Workflows.** Run multi-step [Arazzo](https://spec.openapis.org/arazzo/latest.html) workflows: chain calls, poll until a job finishes, branch on results.
- **Safe by default.** Verified TLS, credentials never follow a redirect to another host, secrets redacted from logs and `--dry-run`.
- **One small static binary** for macOS and Linux, about 2 MB, with no runtime dependencies. Also a [Fennel/Lua library](doc/library.md).

## Install

With [Homebrew](https://brew.sh), on macOS or Linux:

```sh
brew install mpenet/tap/ezu
```

The full name is needed: Homebrew's own `ezu` is another tool. It installs the release binary below, with shell completion.

Or download the binary for your platform from the [releases page](https://github.com/mpenet/ezu/releases) (`ezu-macos-arm64`, `ezu-macos-x86_64`, `ezu-linux-x86_64` or `ezu-linux-arm64`), then:

```sh
install -m 755 ezu-macos-arm64 /usr/local/bin/ezu
ezu --version
```

Every release carries `SHA256SUMS` and a [build provenance attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations):

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing
gh attestation verify ezu-macos-arm64 --repo mpenet/ezu
```

Other ways to install (from source, with luarocks) are in [Installing ezu](doc/install.md).

## Documentation

The [documentation](doc/README.md) has an index of every page. Most used:

- [Installing ezu](doc/install.md), with shell completion.
- [Guide](doc/guide.md): adding an API, credentials, environments, scripting, debugging.
- [Commands](doc/commands.md), [Requests](doc/requests.md), [Output](doc/output.md) and [Configuration](doc/configuration.md): every option and setting.
- [Moving from Restish](doc/restish.md): `ezu profile import-restish` turns a Restish configuration into profiles.
- [Changelog](CHANGELOG.md).

## A five-minute tour

The tour uses the public [Swagger Petstore](https://petstore3.swagger.io). It is a shared demo, so the pets you see will differ.

```sh
export PETSTORE=https://petstore3.swagger.io/api/v3/openapi.json
```

**List what the API can do:**

```console
$ ezu op $PETSTORE --list
add-pet                       Add a new pet to the store.
create-user                   Create user.
delete-pet                    Deletes a pet.
find-pets-by-status           Finds Pets by status.
get-pet-by-id                 Find pet by ID.
...
```

Operation names come from the spec's `operationId`s (`getPetById` → `get-pet-by-id`).

**Read an operation's help:**

```console
$ ezu op $PETSTORE get-pet-by-id --help
GET /pet/{petId}

Find pet by ID.
Returns a single pet.

Usage: ezu op <profile-or-schema> get-pet-by-id <petId>

Path params:
  petId            integer [required] — ID of pet to return

Responses:
  200    successful operation
  400    Invalid ID supplied
  404    Pet not found
  default Unexpected error
```

**Call it.** Path parameters are positional:

```console
$ ezu op $PETSTORE get-pet-by-id 7
{
  "category": {
    "id": 4,
    "name": "Lions"
  },
  "id": 7,
  "name": "Lion 1",
  "photoUrls": [
    "url1",
    "url2"
  ],
  "status": "available",
  "tags": [ ... ]
}
```

**Query parameters, selection and formats:**

```console
$ ezu op $PETSTORE find-pets-by-status --q.status=sold --select '[].{id,name}' --output yaml
- id: 100001
  name: doggie-updated
- id: 54
  name: Roki
...
```

`--select` takes `.field`, `[N]`, `[]` (every element), `{a,b}` (pick fields), filters like `[?status==sold]` and `..field` at any depth. `--output` is `json` (the default), `yaml`, `raw`, `table`, `csv`, `tsv`, `status` or `headers`; see [Output](doc/output.md). Colours are used on a terminal only.

**Send a body.** Fields are typed from the request schema; `-d` takes JSON or YAML, inline, from a file (`@pet.json`) or from stdin (`@-`). Check what would be sent with `--dry-run`, or get a `curl` command with `--curl`:

```console
$ ezu op $PETSTORE add-pet --b.name=Rex --b.status=available --b.photoUrls='["rex.jpg"]' --dry-run
POST https://petstore3.swagger.io/api/v3/pet
accept: application/json, application/xml
content-type: application/json

{"name":"Rex","photoUrls":["rex.jpg"],"status":"available"}
```

ezu checks the request against the spec first, and sends nothing when something is missing:

```console
$ ezu op $PETSTORE add-pet --b.name=Rex
body.photoUrls: required
(use --no-validate to send anyway)
```

**Errors** go to stderr, and the exit code tells them apart: `4` for a 4xx response, `5` for a 5xx, `1` for anything else that went wrong.

```console
$ ezu op $PETSTORE get-pet-by-id 999999999
HTTP 404  0.495s
Pet not found
$ echo $?
4
```

`-v` shows the request and the response headers on stderr, with credentials redacted.

## Profiles and authentication

Name your APIs in `~/.config/ezu/config.json`, with their settings and credentials:

```json
{
  "profiles": {
    "petstore": {
      "schema": "https://petstore3.swagger.io/api/v3/openapi.json",
      "auth": {"name": "bearer", "params": {"token": "env:PETSTORE_TOKEN"}}
    },
    "petstore-yaml": {
      "extends": "petstore",
      "output": "yaml"
    }
  }
}
```

Then use the profile's name instead of the spec's URL:

```console
$ ezu op petstore-yaml get-pet-by-id 7 --select '{name,status}'
name: Lion 1
status: available
```

`env:NAME` reads a secret from the environment. Authentication runs only when a request is actually sent, never for `--help`, `--list` or completion. OAuth tokens are cached and refreshed. See [Configuration](doc/configuration.md), [Authentication](doc/authentication.md) and the [guide](doc/guide.md).

## Workflows

An [Arazzo](https://spec.openapis.org/arazzo/latest.html) document describes a sequence of calls. [`doc/examples/petstore.arazzo.yaml`](doc/examples/petstore.arazzo.yaml) finds a pet by status, then fetches it:

```console
$ ezu az doc/examples/petstore.arazzo.yaml
first-pet  Find the first pet with a given status and fetch its details.

$ ezu az doc/examples/petstore.arazzo.yaml first-pet status=sold --output yaml
name: doggie-updated
status: sold
```

`--arazzo-output progress` shows each step as it runs. Workflows can poll with `goto` and `retry`, branch on success criteria and call other workflows; they use your profiles for authentication. See [Arazzo workflows](doc/arazzo.md).

## AI agents

`ezu mcp` serves an API's operations as tools to Claude, Cursor and other [MCP](https://modelcontextprotocol.io) clients, authenticated with your profile:

```sh
claude mcp add petstore -- ezu mcp petstore
```

Read-only operations by default; see [MCP server](doc/mcp.md).

## Using ezu as a library

The same engine is a Fennel/Lua library: point it at a spec and call operations as functions.

```fennel
(local ezu (require :ezu))
(local petstore (ezu.client "https://petstore3.swagger.io/api/v3/openapi.json"))

(petstore.get-pet-by-id.invoke {:path {:petId 7}})
;; => {:status 200 :headers {...} :body {:id 7 :name "Lion 1" ...}}
```

Install it with `luarocks install ezu`. See the [library documentation](doc/library.md).

## Building from source

```sh
make deps
make test
make binary
```

See [Development](doc/development.md) for the requirements, the release process and the other targets.

## License

Copyright © 2026 Max Penet
Distributed under the Mozilla Public License Version 2.0
