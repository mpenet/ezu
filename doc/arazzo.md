# Arazzo workflows

[Documentation](README.md) › Arazzo workflows

[Arazzo](https://spec.openapis.org/arazzo/latest.html) describes sequences of API calls: call this, take a value from the response, call that, repeat until a job is done. `ezu az` runs Arazzo 1.0 and 1.1 documents, using your [profiles](configuration.md) for authentication and TLS.

It is the natural fit for asynchronous APIs: one workflow starts an operation, polls its status until it completes, and returns the result, in a single command.

## Running a workflow

[`examples/petstore.arazzo.yaml`](examples/petstore.arazzo.yaml) uses the public Petstore: it finds the first pet with a given status, then fetches it.

```console
$ ezu az doc/examples/petstore.arazzo.yaml
first-pet  Find the first pet with a given status and fetch its details.

$ ezu az doc/examples/petstore.arazzo.yaml first-pet --help
first-pet

Find the first pet with a given status and fetch its details.

Usage: ezu az <name-or-file> first-pet [name=value ...]

Inputs:
  status           string [available|pending|sold] (default: available) — Pet status to look for

Steps:
  1. find    findPetsByStatus
  2. fetch   getPetById

$ ezu az doc/examples/petstore.arazzo.yaml first-pet status=sold
{
  "name": "doggie-updated",
  "status": "sold"
}
```

The document is a file path, a URL, or a [name from the configuration](#named-workflow-documents). Without a workflow id, ezu lists the workflows; with `--help`, it describes one: its inputs (type, allowed values, default, description), which inputs can be given as positional arguments, and its steps with what they call.

The OpenAPI documents listed in `sourceDescriptions` are loaded automatically. Relative URLs resolve against the Arazzo document's own location.

## Inputs

Inputs are `name=value` arguments after the workflow id, typed from the workflow's `inputs` schema: `size=50` is a number for an integer input, `force=true` a boolean, a repeated name builds a list (`tag=a tag=b`) and dots build objects (`labels.env=prod`).

```sh
ezu az pets first-pet status=sold

# all at once, inline or from a file; name=value arguments override them
ezu az pets first-pet --inputs '{"status": "sold"}'
ezu az pets first-pet --inputs @inputs.json
```

Arguments that start with `-` are always ezu's options, and arguments shaped like `name=value` are always inputs, so neither a new ezu option nor a new input can change what a command line means. A name the workflow doesn't declare stops ezu with a suggestion (`no input 'sise' in create; did you mean size?`).

A workflow can take some inputs as positional arguments by listing them in `x-ezu-args`, an ezu extension other Arazzo tools ignore:

```yaml
workflows:
  - workflowId: get-instance
    x-ezu-args: [id]
    inputs: {type: object, properties: {id: {type: string}}}
```

```sh
ezu az vm get-instance 0b6f3c2e
```

A positional value shaped like `name=value` (a base64 id ending with `=`) is taken for an assignment; ezu then says to write it `id=…`. When several sources set the same input, the last one wins: the configured `inputs`, `--inputs`, then the arguments.

Inputs are checked against the `inputs` schema before anything runs (types, required inputs, allowed values…); `--no-validate` runs the workflow anyway. Inputs that aren't given take the schema's `default`.

## Output modes

| `--arazzo-output` | Prints |
|-------------------|--------|
| `final` | The workflow's outputs (default) |
| `progress` | A line per step on stderr as the workflow runs, then the workflow's outputs |
| `steps` | Each step's response body, then the outputs |
| `full` | For each step, the operation and request body, then the response, then the outputs |

```console
$ ezu az doc/examples/petstore.arazzo.yaml first-pet --arazzo-output progress
✓ 1/2 find   findPetsByStatus  116ms  200
✓ 2/2 fetch  getPetById        117ms  200
✓ workflow first-pet  960ms
{
  "name": "Lion 1",
  "status": "available"
}
```

Each line gives the step's position, its id, what it calls, how long it took and the response's status, once its success criteria are checked: `✓` when they pass, `✗` when they don't. When an action follows, the line says where it goes (`goto cleanup`, `end`) and, after a failure, which criterion failed and why. A step that runs again (a polling `goto` to itself, or a `retry`) is shown with `↻`, the wait and the criterion that failed, then `✓` with the number of attempts and the total time:

```console
↻ 4/5 wait  get-operation  180ms  200  again in 3s · $response.body#/state == 'success' ($response.body#/state is "pending")
✓ 4/5 wait  get-operation  7 attempts · 21.4s  200
```

On a terminal, a step's line is updated in place while it runs and while it polls, cut to the terminal's width; in a log, each attempt gets its own line. The steps of a workflow run by another one (a step, `dependsOn` or a `goto`) are indented.

A failed workflow ends with `✗ workflow NAME failed` and the reason: the step, the criterion that failed with the values it compared, and the response's status and body (shortened). ezu exits 1. `-v` shows progress as well and logs every request, credentials redacted. Outputs use the `--output` format.

## A document as its own command

A document named in the configuration can become a command of its own: a link to ezu named after it runs its workflows, as `ezu az NAME` does.

```console
$ ezu az vm --link
ln -s "$(command -v ezu)" ~/.local/bin/vm
$ ln -s "$(command -v ezu)" ~/.local/bin/vm
$ vm create-instance name=web1 size=medium --profile exo-pp -v
$ vm get-instance 0b6f3c2e
```

ezu prints the command rather than running it: the name is yours to choose, and so is where the link goes. `vm completion fish` (or `bash`, `zsh`) gives the completion of the new command; `vm --help` lists its workflows. Under its own name, or a name nothing is configured for, ezu is itself.

## Checking a document

`--check` reads the document and its OpenAPI sources and reports what would go wrong, without sending a request to the API:

```console
$ ezu az flows.yaml --check
✗ create-instance › step create: required header parameter 'x-trace' is missing
✗ create-instance › step wait › onFailure poll: goto to unknown step 'wiat'
! create-instance › step create: create-instance has no query parameter 'colour'
2 errors, 1 warning
```

It finds steps calling operations or workflows that don't exist; required parameters left out and parameters the operation doesn't declare (a warning); a body missing or not expected; references to steps, outputs, inputs, workflows, sources and components that don't exist; runtime expressions ezu doesn't know; conditions, regular expressions and JSONPath queries that can't be evaluated (unless they embed `{$expressions}`, only known when running); actions going to unknown steps or workflows. Parameters the profile adds to every request (its headers, query and authentication) count as given; header names match whatever their case, and `Accept`, `Content-Type` and `Authorization` header parameters are left out, as OpenAPI says. Workflows of other Arazzo documents (`$sourceDescriptions.NAME.ID`) are reported, since ezu doesn't run them. With a workflow id, it reports that workflow's problems only, its steps' included. ezu exits 1 when it finds an error, 0 otherwise.

## Named workflow documents

The configuration's `arazzo` section names documents and attaches a profile and default inputs:

```json
{
  "arazzo": {
    "pets": {
      "file": "/home/me/workflows/petstore.arazzo.yaml",
      "profile": "petstore",
      "inputs": {"status": "available"}
    }
  }
}
```

| Key | Description |
|-----|-------------|
| `file` | Path or URL of the document |
| `profile` | Profile whose authentication, headers, TLS and server settings apply to every request |
| `inputs` | Default inputs |

`--profile=NAME` uses another profile for one run. `base-url` and `server-index` are refused when the document has several OpenAPI sources, since they would be ambiguous; server variables go to the sources that declare them.

## Writing workflows

A short reference of what ezu supports. The [Arazzo specification](https://spec.openapis.org/arazzo/latest.html) has the details.

### Steps

A step calls an operation, named by `operationId` (written `$sourceDescriptions.NAME.ID` when several sources define the same id) or `operationPath`, or runs another workflow with `workflowId`. Its `parameters` fill path, query, header and cookie parameters (`in` is required), or the whole query string with `in: querystring`; step parameters replace workflow-level parameters with the same `name` and `in`. `requestBody` gives the body: `payload` (with runtime expressions anywhere inside), `contentType` to override the operation's, and `replacements`, each setting the value at a JSON pointer `target` in the payload, or at every node a JSONPath `target` selects with `targetSelectorType: jsonpath` (one that selects nothing is an error). A `null` in a payload array is sent as `null`; an object member written as `null` in the document is left out, and so is a member whose expression resolves to nothing (an input that isn't given), or a member object whose own members all do: `ssh-key: {name: $inputs.ssh-key}` is left out without an `ssh-key` input. The payload itself, array elements and objects written as `{}` stay objects (`{}`).

`timeout` is the step's request timeout in milliseconds. `dependsOn` lists steps that must run before this one; steps run in order, so a step depending on a later one is an error.

### Runtime expressions

| Expression | Value |
|------------|-------|
| `$inputs.NAME` | A workflow input |
| `$statusCode` | The current response's status |
| `$method`, `$url` | The current request's method and URL |
| `$response.body#/pointer` | Part of the current response body (a [JSON pointer](https://www.rfc-editor.org/rfc/rfc6901)) |
| `$response.header.NAME` | A header of the current response |
| `$request.body#/pointer`, `$request.header.NAME` | The same, for the current request |
| `$request.query.NAME`, `$request.path.NAME` | A query or path parameter of the current request |
| `$steps.ID.outputs.NAME` | An output of an earlier step |
| `$steps.ID.response.body#/pointer`, `$steps.ID.response.header.NAME` | An earlier step's response |
| `$workflows.ID.outputs.NAME`, `$workflows.ID.inputs.NAME` | An output or input of a workflow this one already ran |
| `$outputs.NAME` | In the workflow's `outputs`: one of its outputs defined above |
| `$self` | The Arazzo document's own URL; relative source URLs resolve against it |
| `$sourceDescriptions.NAME.url` | A field of a source description |
| `$find(ARRAY, FIELD, VALUE[, RETURN])` | ezu extension: the first element of `ARRAY` whose `FIELD` is `VALUE`, or its `RETURN` field |
| `{$expression}` | Inside a string: the expression's value |

Arazzo 1.1 `{$expression}` embedding works in regex and JSONPath conditions and in selectors too.

To reach inside an input or output, add a JSON pointer: `$steps.fetch.outputs.pet#/name`. Names may contain dots, so `$steps.fetch.outputs.pet.name` means an output named `pet.name`; when there is none but there is a `pet`, ezu says to use the pointer form.

### Selectors

Wherever a value is expected (outputs, parameter values, payloads), a Selector Object picks part of a value with [JSONPath](https://www.rfc-editor.org/rfc/rfc9535) or a JSON pointer, with runtime expressions embedded in `{}`. One node gives its value, several an array of their values, none no value. This finds an id by name:

```yaml
outputs:
  id:
    context: $response.body
    selector: "$.templates[?@.name == '{$inputs.template}'].id"
    type: jsonpath
```

[`examples/exoscale-instance.arazzo.yaml`](examples/exoscale-instance.arazzo.yaml) uses this to create an Exoscale instance from a template name and an instance type's family and size, then polls the creation job. `type` is `jsonpath` or `jsonpointer`, or an Expression Type Object such as `{type: jsonpath, version: rfc9535}`.

### Success criteria

All of a step's `successCriteria` must hold; a step without any succeeds. A condition that can't be evaluated (a misspelled expression, a malformed pattern) fails, and ezu prints why as a warning on stderr. Three kinds are supported:

- **Simple conditions:** comparisons `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, `!` and parentheses, with strings in single or double quotes (`''` for a quote inside: `'it''s'`), numbers, `true`, `false` and `null`. Strings compare case-insensitively, as the spec requires. Values from responses are compared as values, never read as part of the condition. A misspelled expression (`$statuscode`) fails the condition with a warning, rather than reading as `null`.

  ```yaml
  - condition: $statusCode == 200
  - condition: ($statusCode == 200 || $statusCode == 201) && $response.body#/state != 'failed'
  ```

- **Regular expressions** (`type: regex`) pass when the pattern matches part of the context's value, and never match a missing value. They are ECMAScript regexes, as in the spec's examples, without what can't be matched in linear time: back-references, lookahead and lookbehind are refused, and so are flags. Anchor with `^` and `$` to match the whole value: `^2\d{2}$` matches a 2xx status.

  ```yaml
  - context: $statusCode
    type: regex
    condition: '^2\d{2}$'
  ```

- **JSONPath** (`type: jsonpath`, [RFC 9535](https://www.rfc-editor.org/rfc/rfc9535)) passes when the query selects at least one node of the context. Its `match()` and `search()` functions take [I-Regexp](https://www.rfc-editor.org/rfc/rfc9485) patterns, matched in linear time.

  ```yaml
  - context: $response.body
    type: jsonpath
    condition: "$.items[?@.name == '{$inputs.name}']"
  ```

XPath criteria and selectors are not supported: ezu works with JSON, not XML.

### Actions

After a step, `onSuccess` or `onFailure` decide what happens next; the workflow's `successActions` and `failureActions` apply after the step's own, and a step action replaces a workflow action with the same `name`. The first action whose `criteria` hold is used.

- `end` stops the workflow.
- `goto` continues at `stepId`, or runs `workflowId` and stops. A `goto` to the same step waits `retryAfter` seconds first, which makes polling loops. A workflow aborts after 50 jumps to the same step; raise it with `--max-gotos`.
- `retry` runs the step again after `retryAfter` seconds, at most `retryLimit` times (default 1). With `workflowId` or `stepId`, that workflow or step runs first (to refresh a token, say).

An action that runs a workflow passes it its `parameters` as inputs, or the current workflow's inputs when it has none.

When the response has a `Retry-After` header (seconds or a date), it overrules `retryAfter`, up to `--retry-max-wait` seconds (default 300). A request that fails in transport (connection refused, timeout…) is a step failure like any other, so `retry` handles it too. A step that fails with no action to handle it fails the workflow.

### Polling

A common shape: start a job, then poll until it's done.

```yaml
steps:
  - stepId: start
    operationId: createExport
    successCriteria:
      - condition: $statusCode == 202
    outputs:
      job: $response.body#/id
  - stepId: wait
    operationId: getExport
    parameters:
      - name: id
        in: path
        value: $steps.start.outputs.job
    successCriteria:
      - condition: $response.body#/state == 'done'
    onFailure:
      - name: poll
        type: goto
        stepId: wait
        retryAfter: 5
        criteria:
          - condition: $response.body#/state == 'running'
    outputs:
      url: $response.body#/download_url
```

### Reuse and composition

`components` holds reusable `parameters`, `successActions`, `failureActions` and input schemas; refer to them with `reference: $components.parameters.NAME` (a `value` next to it overrides the component's); input schemas can use `$ref`. Workflows listed in `dependsOn` run first, once each, with the same inputs, and their outputs are available as `$workflows.ID.outputs.NAME`. A step with `workflowId` runs another workflow as a step: its `parameters` are that workflow's inputs, and its criteria, actions and outputs work as for any step (a step without `outputs` exposes the workflow's outputs).

### Not supported

AsyncAPI sources are skipped, and a workflow with steps that send or receive messages (`channelPath`, `action`, `correlationId`, an AsyncAPI `operationId`) is refused before it runs; `$message` is an error. XPath criteria and selectors are refused too.
