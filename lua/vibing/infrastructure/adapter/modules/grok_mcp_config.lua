--- The `mcpServers` list an ACP `session/new` / `session/load` takes, built from the same plugin
--- directories the other backends load.
---
--- **Why this exists at all, when `grok agent --plugin-dir` claims to cover it.** That flag's help
--- says "hooks and MCP servers activate without a prompt", and only the first half is true of grok
--- 1.0.50. Measured: a throwaway plugin declaring a server **both** ways — `mcpServers` in its
--- `.claude-plugin/plugin.json` and a sibling `.mcp.json` — had its `PreToolUse` hook fire, while
--- neither server appeared in `_x.ai/mcp/servers_updated` or in any `_x.ai/mcp/server_status`. Only
--- the four from the user's own `~/.claude.json` did. So the hook travels in the plugin directory
--- and the MCP server has to travel in the session request; two mechanisms, not one.
--- @module vibing.infrastructure.adapter.modules.grok_mcp_config

local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
local PluginContents = require("vibing.infrastructure.plugins.plugin_contents")
local RpcEnvironment = require("vibing.infrastructure.adapter.modules.rpc_environment")

local M = {}

--- What binds a spawned server to the Neovim that launched this chat.
---
--- Forwarded by name rather than left to inheritance. grok spawns the server itself, and whether it
--- hands its own environment on is unmeasured — the same question codex had to be told the answer
--- to explicitly. Taken from the env the adapter already built, so there is one source for the
--- value and `rpc_port` still never appears in a prompt or a tool call (#730).
--- @type string[]
local BOUND_VARS = { RpcEnvironment.PORT_VAR, "VIBING_NVIM_CONTEXT" }

--- ACP wants `env` as a list of `{ name, value }`, not a map.
--- @param declared table<string, string>
--- @param process_env table<string, string>
--- @return table[]
local function env_list(declared, process_env)
  local merged = {}
  for name, value in pairs(declared or {}) do
    merged[name] = value
  end
  for _, name in ipairs(BOUND_VARS) do
    local value = process_env and process_env[name]
    if value then
      merged[name] = value
    end
  end

  local out = {}
  for name, value in pairs(merged) do
    table.insert(out, { name = name, value = tostring(value) })
  end
  -- Sorted so one chat's `session/new` is byte-identical to the next's. `pairs` order is undefined,
  -- and this payload is the kind of thing a fixture compares.
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

--- @param server Vibing.PluginMcpServer
--- @param process_env table<string, string>
--- @return table
local function spec(server, process_env)
  if not server.command then
    return { name = server.name, url = server.url }
  end
  return {
    name = server.name,
    command = server.command,
    args = server.args or {},
    env = env_list(server.env, process_env),
  }
end

--- Every server the loaded plugins declare, in plugin-directory order.
---
--- Deduplicated first-plugin-wins, matching the precedence `--plugin-dir` itself gives a duplicate
--- on the other backends: a project plugin cannot displace the bundled `vibing-nvim` server by
--- declaring one of its own.
---
--- Empty for a lightweight call, which owes "no user MCP servers" (`core/types.lua`). `session/new`
--- **requires** the field either way — omitting it is an `Invalid params` error naming it, not a
--- default — so the empty list is the answer, never `nil`.
--- @param params Vibing.DuplexRunParams
--- @return table[]
function M.servers(params)
  if params.opts and params.opts.lightweight then
    return {}
  end

  local seen, out = {}, {}
  for _, dir in ipairs(PluginDirs.resolve(params.opts and params.opts.cwd, params.config)) do
    for _, server in ipairs(PluginContents.mcp_servers(dir)) do
      if not seen[server.name] then
        seen[server.name] = true
        table.insert(out, spec(server, params.env))
      end
    end
  end
  return out
end

return M
