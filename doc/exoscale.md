# Exoscale with ezu

[Documentation](README.md) › Exoscale with ezu

ezu ships Exoscale's `exo` command line as [Arazzo workflows](arazzo.md): about 400 commands over the Exoscale API, from instances to databases, Kubernetes, DNS, IAM and KMS. This page sets them up as a command of their own, `exo`, signed by a [plugin](authentication.md#plugins).

```console
$ exo compute instance create web1 size=large ssh-key=me labels.env=prod
$ exo compute instance list --output=table
$ exo compute sks nodepool add k8s workers size=3
$ exo dbaas create pg db1 hobbyist-2
$ exo dns add example.com A name=www content=192.0.2.1
```

The workflows are in [`examples/`](examples/): [`exoscale.arazzo.yaml`](examples/exoscale.arazzo.yaml) mounts `compute` (with `compute sks`), `dbaas`, `dns`, `iam`, `kms`, `ai` and `networking`, each a document of its own, and lists zones, quotas, events and the organization's usage itself. The steps they share, finding a resource's id from its name and waiting for a job to finish, are in [`exoscale-common.arazzo.yaml`](examples/exoscale-common.arazzo.yaml).

## Signing requests

Exoscale signs each request with the API key's secret (EXO2-HMAC-SHA256). The plugin [`examples/plugins/exoscale.fnl`](examples/plugins/exoscale.fnl) does it inside ezu. Install it where only you can change it, since it runs with your credentials:

```sh
mkdir -p ~/.config/ezu/plugins && chmod 700 ~/.config/ezu/plugins
install -m 600 doc/examples/plugins/exoscale.fnl ~/.config/ezu/plugins/
```

Then, in `~/.config/ezu/config.json`, list the plugin and give a profile the key and its secret:

```json
{
  "plugins": ["~/.config/ezu/plugins/exoscale.fnl"],
  "profiles": {
    "exo": {
      "auth": {"name": "exoscale",
               "params": {"key": "EXO…", "secret": "…"}}
    }
  }
}
```

A profile without `schema` or `base-url` uses the spec's server, `https://api-{zone}.exoscale.com/v2`, in zone `ch-gva-2`. `"server": {"zone": "de-fra-1"}` in the profile picks another zone, and `--server.zone=at-vie-1` another for one command. An environment of your own (a preproduction API, say) is a `base-url` and the spec it serves: `"base-url": "https://…/v2", "schema": "https://…/v2/openapi.json"`.

## Where the key and secret live

The key is an identifier, sent as it is in every request's `Authorization` header; the secret is what to protect. Any [secret source](authentication.md#secrets) works for either:

| Where | `params` | Cost per command |
|-------|----------|------------------|
| The configuration (`chmod 600`, as ezu writes it) | `"secret": "…"` | none |
| The environment | `"secret": {"env": "EXOSCALE_API_SECRET"}` | none |
| A private file | `"secret": {"file": "~/.config/ezu/secrets/exo"}` | a file read |
| The macOS Keychain | `"secret": {"cmd": ["security", "find-generic-password", "-s", "ezu-exo-secret", "-w"]}` | about 25 ms |
| A Linux desktop's keyring | `"secret": {"cmd": ["secret-tool", "lookup", "service", "ezu-exo-secret"]}` | a command run |

A source is read once per command, when a request needs it: a workflow of twenty steps reads it once, and `--help`, `--check`, completion and dry runs never do. With the Keychain, keep the key in the configuration and only the secret in the Keychain: one lookup per command instead of two. Store it once with:

```sh
security add-generic-password -s ezu-exo-secret -a "$USER" -T /usr/bin/security -w
```

`-T /usr/bin/security` lets `security` read the entry without asking each time.

## The `exo` command

Name the index in the configuration, with the profile it runs with:

```json
"arazzo": {
  "exo": {"file": "/path/to/ezu/doc/examples/exoscale.arazzo.yaml",
          "profile": "exo",
          "arazzo-output": "progress"}
}
```

`ezu az exo compute instance list` works from there; `ezu az exo --link` prints the command that makes `exo` a command of its own, and `exo completion fish` (or `bash`, `zsh`) its completion. `arazzo-output: progress` shows each step as it runs; leave it out for the outputs alone.

```console
$ exo
ai            AI models, deployments on GPUs, AI API keys…
compute       Instances, security groups, elastic IPs, private networks, block storage…
dbaas         Database services (PostgreSQL, MySQL, Kafka, OpenSearch, Valkey…), users, databases, integrations…
…
$ exo compute instance stop --help
```

Commands take resources by name or by id, as `exo` does; a name two resources share is refused rather than guessed. Changes wait for Exoscale's job to finish, then show the result.

- **Lists as tables:** `exo compute instance list --output=table`, or `--select='.instances[].{name,state}'` to pick fields.
- **Questions first:** deleting, resetting, reverting, evicting, stopping and rebooting ask before they run (`Delete instance web1? [y/N]`); `--yes` answers for scripts, and without a terminal ezu stops rather than guess.
- **Completion of names:** Tab after a command offers your instances, security groups, clusters, nodepools, domains, database services and more, listed from the API with the profile's credentials and kept a minute.
- **Speed:** the Exoscale spec is fetched once an hour and cached; a command then takes about a tenth of a second plus the API's own time. `--reload` fetches it again.
- **Checking:** `exo --check` checks every document against the spec without sending anything.

## For AI agents

`ezu mcp --arazzo exo` offers the commands to an agent (see [MCP server](mcp.md)), named by their words: `workflow.compute_instance_list`. All of them are a lot of tools; list the ones to offer in the document's configuration:

```json
"exo": {"file": "…", "profile": "exo",
        "mcp": {"workflows": ["compute instance list", "compute instance show", "dns *"]}}
```

Without a list, commands that ask first are left out unless `--allow-writes` is given: an agent can't be asked.

## Limits

Arazzo can repeat a step, but not walk through a list: nothing gives the next item or counts. So a list of names can't become a list of ids, and a command takes one name where `exo` may take several (one security group or private network at instance creation); where the API takes ids, several can be given, repeated: `exo compute instance-pool evict web instances=ID instances=ID`. Some `exo` options aren't there (cloud-init files, DHCP options of private networks), and a few command words differ (`exo dbaas create pg NAME PLAN` takes the engine as a word). The workflows were checked against the spec and a mock of the API; report what a real account shows differently.
