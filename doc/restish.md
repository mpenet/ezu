# Moving from Restish

[Documentation](README.md) › Moving from Restish

`ezu profile import-restish` adds your Restish APIs to the ezu configuration as profiles:

```sh
# show what would be added
ezu profile import-restish --dry-run

# add them; the previous configuration is kept as config.json.bak
ezu profile import-restish

# from a specific file
ezu profile import-restish ~/path/to/restish.json
```

Without a path, ezu looks where Restish does: `restish.json` (Restish 2) or the older `apis.json`, in `$RSH_CONFIG_DIR`, `$XDG_CONFIG_HOME/restish`, `~/.config/restish`, `~/Library/Application Support/restish` and `~/.restish`.

Each API becomes a profile with the API's name; its other profiles become `API.PROFILE`. Existing ezu profiles with the same name are kept, never overwritten.

| Restish | ezu profile |
|---------|---------------|
| `base` / `base_url` (with `operation_base`) | `base-url` |
| `spec_files[0]` / `spec_url` | `schema` |
| `headers`, `query` | `headers`, `query` |
| `tls`, or `client_cert`, `client_key`, `ca_cert`, `insecure` | `tls` |
| `server_variables` | `server`, for an API without a base URL |
| `auth` (`name` or `type`), `auth_ref` | `auth`; `http-basic` → `basic`, `oauth-device-code` → `oauth-device-authorization`, `scopes` → `scope` |

Settings with no ezu equivalent are listed as warnings rather than dropped silently: APIs without `spec_files` or a base URL, extra `spec_files`, `issuer_url` (OIDC discovery), `credentials`, `tls_signer`, `url_overrides`, `pagination`, and `server_variables` next to a base URL (ezu sends requests to the base URL as it is, and refuses server variables with it).

Commands map directly: `restish example list-items` becomes `ezu op example list-items`.

## How they differ

Most of what you do with Restish has a direct equivalent:

| Restish | ezu |
|---------|-------|
| `restish example list-items` | `ezu op example list-items` |
| Spec discovery from the API's base URL | the same, for a profile with `base-url` and no `schema` |
| `restish get https://…`, `restish post https://… name: x` | `ezu http GET https://…`, `ezu http POST https://… --b.name=x` |
| Shorthand body input (`name: x, tags[]: a`) | `-d` with JSON or YAML, `--b.name=x` fields (`--b.disk.size=10` for nested ones) |
| `-f body.items[state == running].{id, name}` | `--select '.items[?state==running].{id,name}'` |
| `-f 'body..name'`, `-f 'body.items[-1]'` | `--select '..name'`, `--select '.items[-1]'` |
| `--rsh-filter-lang jq` | pipe the JSON output to `jq` |
| CSV formatter plugin | `--output=csv`, `tsv` or `table` |
| MCP command plugin | `ezu mcp PROFILE` |
| TLS signer and auth hook plugins | [Auth plugins](authentication.md#plugins) in Lua or Fennel, run inside ezu, or `external-tool` authentication for any command that signs or fetches credentials |

ezu also:

- checks a request against the spec before sending it: required parameters, and the body against its schema;
- runs [Arazzo](arazzo.md) workflows, and offers them to AI agents through `ezu mcp --arazzo`;
- is one static binary of about 2 MB, with these features built in rather than installed as plugins; its own plugins are Lua or Fennel files, with nothing to install.

See the [Restish documentation](https://rest.sh/docs/) for its side of the comparison.
