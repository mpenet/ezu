# Authentication

[Documentation](README.md) › Authentication

A profile's `auth` names a method and its parameters. A parameter can be written in the configuration, or read from where your secrets are kept; see [Secrets](#secrets).

Authentication runs only when a request is sent: never for `--help`, `--list`, `--servers`, `--dry-run` or completion, nor when the request's own headers already provide what it would add. A spec fetched from a URL is requested without credentials first, and with them only if the server answers 401 or 403; when the profile's `base-url` is on another origin than the spec, the spec gets neither credentials nor the profile's `headers`. Credentials are computed once per command, reused by retries and pagination, and a header given explicitly (with `--h.` or in the profile's `headers`) wins over the one authentication adds.

## Secrets

A value that is a secret, an auth parameter, or a profile's `headers` or `query` value, can come from elsewhere than the configuration:

| Value | Read from |
|-------|-----------|
| `{"env": "NAME"}`, or `"env:NAME"` | The environment variable `NAME` |
| `{"file": "~/.config/ezu/secrets/exo"}` | A file of yours that no one else can read or change (`chmod 600`), without its last newline |
| `{"cmd": ["security", "find-generic-password", "-s", "exo", "-w"]}` | What a command prints, without its last newline; its arguments go as written, through no shell |

```json
"auth": {"name": "exoscale",
         "params": {"key": "EXO...",
                    "secret": {"cmd": ["security", "find-generic-password", "-s", "exo-pp", "-w"]}}}
```

A secret is read when a request needs it, once per command, and never for `--dry-run`, `--help` or completion. Errors name the value (`params.secret: command security failed (exit 44)`), never what it holds. Headers and query values read this way count as credentials, as authentication's do: redacted in logs and `--curl`, and dropped when a redirect leads to another origin.

Where to keep them:

- **macOS:** the Keychain, `{"cmd": ["security", "find-generic-password", "-s", "NAME", "-w"]}` (store it once with `security add-generic-password -s NAME -a "$USER" -w`).
- **Linux desktop:** the Secret Service (GNOME Keyring, KDE Wallet), `{"cmd": ["secret-tool", "lookup", "service", "NAME"]}` (store it with `secret-tool store --label=NAME service NAME`).
- **Password managers:** `{"cmd": ["op", "read", "op://vault/item/field"]}`, `{"cmd": ["pass", "show", "NAME"]}`, `{"cmd": ["bw", "get", "password", "NAME"]}`.
- **Servers, containers, CI:** a file the platform provides (`/run/secrets/NAME`, systemd's `$CREDENTIALS_DIRECTORY`), or the environment.

## `bearer`

```json
{"name": "bearer", "params": {"token": "env:API_TOKEN"}}
```

Sends `Authorization: Bearer <token>`.

## `basic`

```json
{"name": "basic", "params": {"username": "me", "password": "env:API_PASSWORD"}}
```

## `api-key`

```json
{"name": "api-key", "params": {"name": "X-API-Key", "in": "header", "value": "env:API_KEY"}}
```

With `"in": "query"`, the key is sent as a query parameter instead, and with `"in": "cookie"` as a cookie; `header` is the default.

## `oauth-authorization-code`

Opens the browser, receives the code on a local callback server, and exchanges it for a token, with PKCE (S256).

| Param | Description |
|-------|-------------|
| `authorize_url` | The provider's authorization endpoint |
| `token_url` | The provider's token endpoint |
| `client_id` | Client id |
| `client_secret` | Client secret; leave it out for a public client |
| `scope` | Scopes, space-separated |
| `redirect_host`, `redirect_port`, `redirect_path` | The callback address, which must match a redirect URI registered with the provider (default `127.0.0.1`, a random port, `/callback`) |

## `oauth-client-credentials`

For services and CI: `token_url`, `client_id`, `client_secret`, and optionally `scope` and `audience`.

## `oauth-device-authorization`

For machines without a browser: prints a code and a URL on stderr, then waits while you approve on another device. Params: `device_authorization_url`, `token_url`, `client_id`, and optionally `client_secret` and `scope`.

OAuth tokens are cached in `~/.cache/ezu/tokens/<profile>.json` (mode 0600; `$XDG_CACHE_HOME` replaces `~/.cache` when set) and refreshed when they expire. `ezu auth <profile>` signs in again; `ezu auth <profile> --logout` deletes the token.

## `external-tool`

Runs a command (through `/bin/sh -c`) that provides the credentials.

| Param | Description |
|-------|-------------|
| `commandline` | The command |
| `output` | `bearer-token` to read a token, see below; leave out to sign each request |
| `omitbody` | `true` to leave the body out of what the command receives |

To sign requests, the command runs for every request. It receives the request on stdin:

```json
{"method": "GET", "uri": "https://api.example.com/items?a=1", "headers": {}, "body": ""}
```

and prints the headers to add on stdout:

```json
{"headers": {"X-Signature": ["abc123"]}}
```

With `"output": "bearer-token"`, the command runs once per ezu invocation, receives nothing, and prints a token; ezu sends `Authorization: Bearer <token>`.

## Plugins

A plugin is a Lua or Fennel file that provides authentication methods, used by name like the built-in ones. It runs inside ezu: no process is started for each request, and a Fennel file needs nothing installed, since ezu carries the Fennel compiler. List plugins in the [configuration](configuration.md):

```json
{
  "plugins": ["~/.config/ezu/plugins/exoscale.fnl"],
  "profiles": {
    "exo": {
      "schema": "https://openapi-v2.exoscale.com/source.json",
      "auth": {"name": "exoscale",
               "params": {"key": "env:EXOSCALE_API_KEY", "secret": "env:EXOSCALE_API_SECRET"}}
    }
  }
}
```

The file returns a table whose `auth` maps names to functions. A function gets each request as it is sent, `{:method :url :headers :body}` (the URL with its query string, the body encoded), the profile's `params` (`env:NAME` values read from the environment), and helpers; it returns the headers to add, which ezu treats as credentials (redacted in logs, never sent to another origin):

```fennel
{:auth {:example (fn [req params ezu]
                   {:headers {:x-signature (ezu.hex (ezu.hmac_sha256 params.secret
                                                                         (.. req.method " " req.url)))}})}}
```

| Helper | |
|--------|---|
| `sha256(text)`, `hmac_sha256(key, text)` | Digests, as raw bytes |
| `base64(bytes)`, `unbase64(text)`, `hex(bytes)` | Encodings |
| `json.encode`, `json.decode` | JSON |
| `url.parse(url)` | `{scheme, host, port, path, query}`, the path as sent (`;params` included) |
| `url.query(query)` | The query string's parameters, decoded, in order: `[[name, value], ...]` |

[`examples/plugins/exoscale.fnl`](examples/plugins/exoscale.fnl) signs Exoscale's API requests, about 40 lines. The digests are computed in Lua: signing takes well under a millisecond for an API request, but about half a second for a 1 MB body.

Plugins are loaded only when a profile uses a name ezu doesn't provide, to find which one provides it: their top-level code runs then, even with `--dry-run`, which only leaves out the signing. A plugin runs with your credentials, so its path must start with `/` or `~/`, and ezu refuses a plugin file that isn't yours, that others can change (`chmod go-w`) or that has an access list, and one in a directory, up to `/`, that isn't yours or root's or that others can change (sticky directories like `/tmp` excepted). It also refuses a name provided by two plugins or by ezu itself. `ezu auth PROFILE` says which plugin signs its requests. Header names a plugin returns are sent in lowercase. Installed as a library, ezu needs the `fennel` module for Fennel plugins.
