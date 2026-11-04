--- The `mcpServers` list an ACP `session/new` / `session/load` takes, built from the same plugin
--- directories the other backends load.
---
--- **Why this exists at all, when the plugin directory is already loaded.** The plugin carries the
--- `execute.before` hook, but the MCP servers its manifest declares are not part of the ACP session
--- OpenCode creates. ACP asks for them on `session/new`, so the hook travels in
--- `OPENCODE_CONFIG_CONTENT` and the server list travels in the session request; two mechanisms,
--- not one.
--- @module vibing.infrastructure.adapter.modules.opencode_mcp_config

local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
local PluginContents = require("vibing.infrastructure.plugins.plugin_contents")
local RpcEnvironment = require("vibing.infrastructure.adapter.modules.rpc_environment")
local ToolVocabulary = require("vibing.infrastructure.adapter.modules.opencode_tool_vocabulary")

local M = {}

--- What binds a spawned server to the Neovim that launched this chat.
---
--- Forwarded by name rather than left to inheritance. opencode spawns the server itself, and whether it
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

--- ACP wants `headers` as a list of `{ name, value }` too.
--- @param declared table<string, string>|nil
--- @return table[]
local function header_list(declared)
  local out = {}
  for name, value in pairs(declared or {}) do
    table.insert(out, { name = name, value = tostring(value) })
  end
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
    -- ACP's HTTP shape is discriminated by `type`; without it the entry reads as stdio and
    -- `session/new` rejects the malformed server.
    return { type = "http", name = server.name, url = server.url, headers = header_list(server.headers) }
  end
  return {
    name = server.name,
    command = server.command,
    args = server.args or {},
    env = env_list(server.env, process_env),
  }
end

--- @class Vibing.OpenCodeMcpResolution
--- @field servers table[] the `mcpServers` list `session/new` takes

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
--- @return Vibing.OpenCodeMcpResolution
function M.resolve(params)
  if params.opts and params.opts.lightweight then
    return { servers = {} }
  end

  local seen, names, out = {}, {}, {}
  for _, dir in ipairs(PluginDirs.resolve(params.opts and params.opts.cwd, params.config)) do
    for _, server in ipairs(PluginContents.mcp_servers(dir)) do
      if not seen[server.name] then
        seen[server.name] = true
        table.insert(names, server.name)
        table.insert(out, spec(server, params.env))
      end
    end
  end
  ToolVocabulary.set_mcp_servers(names)
  return { servers = out }
end

return M
