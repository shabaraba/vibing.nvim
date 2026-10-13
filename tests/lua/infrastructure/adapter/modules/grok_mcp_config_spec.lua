---@diagnostic disable: undefined-field
--- The `mcpServers` list an ACP `session/new` / `session/load` takes.
---
--- `grok agent --plugin-dir` carries a plugin's hook but not its MCP servers (measured on 1.0.50:
--- neither a manifest `mcpServers` nor a sibling `.mcp.json` ever appeared in
--- `_x.ai/mcp/servers_updated`), so the servers travel in the session request instead. The plugin
--- tree is stubbed here: what is under test is the payload's shape, not which directories apply.
local MODULE = "vibing.infrastructure.adapter.modules.grok_mcp_config"
local DIRS = "vibing.infrastructure.plugins.plugin_dirs"
local CONTENTS = "vibing.infrastructure.plugins.plugin_contents"

describe("grok_mcp_config", function()
  local McpConfig, resolved

  --- @param dirs string[] what `plugin_dirs.resolve` returns, in its own order
  --- @param by_dir table<string, Vibing.PluginMcpServer[]> what each directory declares
  --- @param self_dir string|nil which of them is the bundled plugin, matched by path
  local function load(dirs, by_dir, self_dir)
    resolved = {}
    package.loaded[DIRS] = {
      resolve = function(cwd, config)
        table.insert(resolved, { cwd = cwd, config = config })
        return dirs
      end,
      self_plugin_dir = function()
        return self_dir
      end,
    }
    package.loaded[CONTENTS] = {
      mcp_servers = function(dir)
        return by_dir[dir] or {}
      end,
    }
    package.loaded[MODULE] = nil
    McpConfig = require(MODULE)
  end

  after_each(function()
    package.loaded[MODULE] = nil
    package.loaded[DIRS] = nil
    package.loaded[CONTENTS] = nil
  end)

  --- @param opts table|nil
  --- @param env table<string, string>|nil
  local function params(opts, env)
    return {
      config = { agent = {} },
      opts = opts,
      env = env or { VIBING_NVIM_RPC_PORT = "9876", VIBING_NVIM_CONTEXT = "true", HOME = "/Users/x" },
    }
  end

  -- `session/new` **requires** the field: omitting it is an `Invalid params` error naming it, not a
  -- default. So a lightweight call, which owes "no user MCP servers" (`core/types.lua`), answers
  -- with the empty list rather than nil.
  it("hands a lightweight call an empty list, never nil", function()
    load({ "/p/self" }, { ["/p/self"] = { { name = "vibing-nvim", command = "sh" } } })

    local servers = McpConfig.resolve(params({ lightweight = true })).servers

    assert.is_table(servers)
    assert.same({}, servers)
    -- Not merely filtered afterwards: the plugin tree is never read, so nothing a plugin declares
    -- can reach a lightweight turn.
    assert.same({}, resolved)
  end)

  it("resolves the plugin directories for the chat's own working directory", function()
    load({}, {})

    local config = { agent = {} }
    McpConfig.resolve({ config = config, opts = { cwd = "/repo/worktree" }, env = {} })

    assert.same({ { cwd = "/repo/worktree", config = config } }, resolved)
  end)

  it("emits env as ACP's list of name/value pairs, sorted by name", function()
    load({ "/p/self" }, {
      ["/p/self"] = {
        {
          name = "vibing-nvim",
          command = "sh",
          args = { "/p/self/mcp-server/bin/run.sh" },
          env = { ZULU = "1", MIKE = "2", ECHO = "3", VICTOR = "4", BRAVO = "5", TANGO = "6" },
        },
      },
    })

    local servers = McpConfig.resolve(params(nil, { VIBING_NVIM_RPC_PORT = "9876" })).servers

    assert.same({
      {
        name = "vibing-nvim",
        command = "sh",
        args = { "/p/self/mcp-server/bin/run.sh" },
        env = {
          { name = "BRAVO", value = "5" },
          { name = "ECHO", value = "3" },
          { name = "MIKE", value = "2" },
          { name = "TANGO", value = "6" },
          { name = "VIBING_NVIM_RPC_PORT", value = "9876" },
          { name = "VICTOR", value = "4" },
          { name = "ZULU", value = "1" },
        },
      },
    }, servers)
  end)

  -- Forwarded by name rather than left to inheritance: grok spawns the server itself and whether it
  -- hands its own environment on is unmeasured. Taken from the env the adapter already built, so
  -- `rpc_port` still never appears in a prompt or a tool call (#730).
  it("forwards only the two variables that bind a server to this Neovim", function()
    load({ "/p/self" }, { ["/p/self"] = { { name = "vibing-nvim", command = "sh" } } })

    local env = McpConfig.resolve(params()).servers[1].env
    local by_name = {}
    for _, pair in ipairs(env) do
      by_name[pair.name] = pair.value
    end

    assert.equals("9876", by_name.VIBING_NVIM_RPC_PORT)
    assert.equals("true", by_name.VIBING_NVIM_CONTEXT)
    assert.is_nil(by_name.HOME)
  end)

  it("omits a bound variable the adapter's env does not carry", function()
    load({ "/p/self" }, { ["/p/self"] = { { name = "vibing-nvim", command = "sh" } } })

    assert.same({}, McpConfig.resolve(params(nil, {})).servers[1].env)
  end)

  -- The same precedence `--plugin-dir` gives a duplicate on the other backends: a project plugin
  -- cannot displace the bundled `vibing-nvim` server by declaring one of its own.
  -- By path, not by name: with `integrations.plugins.self = false` a project plugin could carry the name
  -- `vibing-nvim`, and the session's first prompt would then name a tool on somebody else's server.
  it("names the bundled server by the directory it came from", function()
    load({ "/p/self", "/p/other" }, {
      ["/p/self"] = { { name = "vibing-nvim", command = "sh" } },
      ["/p/other"] = { { name = "other", command = "sh" } },
    }, "/p/self")

    assert.equals("vibing-nvim", McpConfig.resolve(params(nil, {})).self_server)
  end)

  it("reports no bundled server when the bundled plugin is not loaded", function()
    load({ "/p/other" }, { ["/p/other"] = { { name = "vibing-nvim", command = "sh" } } }, "/p/self")

    local resolution = McpConfig.resolve(params(nil, {}))
    assert.equals(1, #resolution.servers)
    assert.is_nil(resolution.self_server)
  end)

  it("deduplicates by name, first plugin directory winning", function()
    load({ "/p/self", "/p/project" }, {
      ["/p/self"] = { { name = "vibing-nvim", command = "sh" } },
      ["/p/project"] = { { name = "vibing-nvim", command = "evil" }, { name = "deploybot", command = "serve" } },
    })

    local servers = McpConfig.resolve(params(nil, {})).servers

    assert.same({ "vibing-nvim", "deploybot" }, vim.tbl_map(function(s)
      return s.name
    end, servers))
    assert.equals("sh", servers[1].command)
  end)

  it("describes a streamable HTTP server by url alone", function()
    load({ "/p/remote" }, { ["/p/remote"] = { { name = "hosted", url = "https://x.test/mcp" } } })

    assert.same({ { name = "hosted", url = "https://x.test/mcp" } }, McpConfig.resolve(params()).servers)
  end)

  it("defaults a stdio server's args to an empty list", function()
    load({ "/p/self" }, { ["/p/self"] = { { name = "bare", command = "serve" } } })

    assert.same({}, McpConfig.resolve(params(nil, {})).servers[1].args)
  end)
end)
