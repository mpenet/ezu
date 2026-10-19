rockspec_format = "3.0"
package = "ezu"
version = "dev-1"

source = {
  url = "git+https://github.com/mpenet/ezu",
}

description = {
  summary = "OpenAPI 3.x client and CLI toolbox for Fennel/Lua",
  detailed = [[
    Dynamically builds a callable client from any OpenAPI 3.x schema at runtime
    (file path, URL, or parsed table; JSON or YAML). No code generation required.
    Also ships a standalone CLI (ezu) similar to Restish, with profiles,
    OAuth 2.0, mTLS, schema caching, and shell completion. HTTP goes through
    libcurl.
  ]],
  license = "MPL-2.0",
  homepage = "https://github.com/mpenet/ezu",
}

dependencies = {
  "lua >= 5.4",
  "lunajson",
  "luasocket",
  "lyaml",
}

build_dependencies = {
  "fennel",
}

external_dependencies = {
  CURL = { header = "curl/curl.h" },
}

build = {
  -- sources are Fennel; compile them, then install the generated Lua
  type = "command",
  -- needs the fennel executable on PATH (the build dependency's tree bin dir)
  build_command = "make build LUA_INC=$(LUA_INCDIR) CURL_CFLAGS=-I$(CURL_INCDIR) 'CURL_LIBS=-L$(CURL_LIBDIR) -lcurl'",
  install = {
    lua = {
      ["ezu"]           = "lua/ezu.lua",
      ["ezu.auth"]      = "lua/ezu/auth.lua",
      ["ezu.secrets"] = "lua/ezu/secrets.lua",
      ["ezu.trusted-file"] = "lua/ezu/trusted-file.lua",
      ["ezu.cache"]     = "lua/ezu/cache.lua",
      ["ezu.cli"]       = "lua/ezu/cli.lua",
      ["ezu.cli.args"]  = "lua/ezu/cli/args.lua",
      ["ezu.cli.complete"] = "lua/ezu/cli/complete.lua",
      ["ezu.cli.help"]  = "lua/ezu/cli/help.lua",
      ["ezu.cli.mcp"] = "lua/ezu/cli/mcp.lua",
      ["ezu.cli.output"] = "lua/ezu/cli/output.lua",
      ["ezu.cli.width"] = "lua/ezu/cli/width.lua",
      ["ezu.cli.progress"] = "lua/ezu/cli/progress.lua",
      ["ezu.cli.plugins"] = "lua/ezu/cli/plugins.lua",
      ["ezu.arazzo.check"] = "lua/ezu/arazzo/check.lua",
      ["ezu.arazzo.commands"] = "lua/ezu/arazzo/commands.lua",
      ["ezu.unicode-categories"] = "lua/ezu/unicode-categories.lua",
      ["ezu.iregexp"] = "lua/ezu/iregexp.lua",
      ["ezu.jsonpath"] = "lua/ezu/jsonpath.lua",
      ["ezu.cli.request"] = "lua/ezu/cli/request.lua",
      ["ezu.cli.restish"] = "lua/ezu/cli/restish.lua",
      ["ezu.cli.settings"] = "lua/ezu/cli/settings.lua",
      ["ezu.coerce"]    = "lua/ezu/coerce.lua",
      ["ezu.digest"]    = "lua/ezu/digest.lua",
      ["ezu.doc"]       = "lua/ezu/doc.lua",
      ["ezu.http"]      = "lua/ezu/http.lua",
      ["ezu.json"] = "lua/ezu/json.lua",
      ["ezu.negotiate"] = "lua/ezu/negotiate.lua",
      ["ezu.paginate"]  = "lua/ezu/paginate.lua",
      ["ezu.pretty"]    = "lua/ezu/pretty.lua",
      ["ezu.refs"]      = "lua/ezu/refs.lua",
      ["ezu.retry"]     = "lua/ezu/retry.lua",
      ["ezu.tls"] = "lua/ezu/tls.lua",
      ["ezu.util"]      = "lua/ezu/util.lua",
      ["ezu.validate"]  = "lua/ezu/validate.lua",
      ["ezu.arazzo"]    = "lua/ezu/arazzo.lua",
      ["ezu.arazzo.expr"] = "lua/ezu/arazzo/expr.lua",
      ["ezu.yaml"]      = "lua/ezu/yaml.lua",
    },
    lib = { ["ezu.curl"] = "lua/ezu/curl.so" },
    bin = { ezu = "bin/ezu" },
  },
}
