;; ABOUTME: Entry point for the standalone ezu binary: preloads every bundled
;; ABOUTME: module so the static build can resolve them, then runs the CLI.
;; fennel --require-as-include cannot follow the requires of the modules it
;; includes, so every dependency must be required directly from the entry
;; point, and before any module that requires it.
(require :lunajson.decoder)

(require :lunajson.encoder)

(require :lunajson.sax)

(require :lunajson)

(require :ezu.json)

(require :socket)

(require :socket.url)

(require :ezu.util)

(require :ezu.digest)

(require :ezu.refs)

(require :ezu.coerce)

(require :ezu.validate)

(require :ezu.retry)

(require :ezu.paginate)

(require :ezu.yaml)

(require :ezu.negotiate)

(require :ezu.doc)

(require :ezu.tls)

(require :ezu.http)

(require :ezu.pretty)

(require :ezu.cache)

(require :ezu.auth)

(require :ezu.cli.plugins)

(require :ezu)

(require :ezu.unicode-categories)

(require :ezu.iregexp)

(require :ezu.jsonpath)

(require :ezu.arazzo.expr)

(require :ezu.arazzo)

(require :ezu.arazzo.commands)

(require :ezu.arazzo.check)

(require :ezu.cli.request)

(require :ezu.cli.args)

(require :ezu.cli.width)

(require :ezu.cli.progress)

(require :ezu.cli.output)

(require :ezu.cli.settings)

(require :ezu.cli.help)

(require :ezu.cli.restish)

(require :ezu.cli.complete)

(require :ezu.cli.mcp)

(require :ezu.cli)

(local cli (require :ezu.cli))

(cli.main arg)
