--- The `mcpServers` list Command Code's ACP `session/new` / `session/load` takes, built from the
--- same plugin directories the other backends load.
---
--- **Why this exists at all, when the plugin directory is not passed.** Command Code has no
--- `--plugin-dir` and no per-run MCP flag; the servers in `.mcp.json`, `~/.commandcode/mcp.json`
--- and `~/.commandcode/projects/<slug>/mcp.json` are the user's own. ACP asks the client for the
--- servers instead — `createAgentSession` hands them to `connectEditorMcpServers` — so the skills
--- travel with `--skill` and the servers travel in the session request: two mechanisms, not one.
---
--- The entry shape is the one Command Code parses there: a stdio server is
--- `{name, command, args, env = [{name, value}]}` and an HTTP one is `{name, url, headers =
--- [{name, value}]}` (an entry with `type = "sse"` is skipped by the CLI; `http` is the default
--- when `type` is absent). Verified against 1.88.2.
--- @module vibing.infrastructure.adapter.modules.commandcode_mcp_config

local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
local PluginContents = require("vibing.infrastructure.plugins.plugin_contents")
local RpcEnvironment = require("vibing.infrastructure.adapter.modules.rpc_environment")

local M = {}

--- What binds a spawned server to the Neovim that launched this chat.
---
--- Forwarded by name rather than left to inheritance. Command Code spawns the server itself, and
--- whether it hands its own environment on is unmeasured — the same question codex had to be told
--- the answer to explicitly. Taken from the env the adapter already built, so there is one source
--- for the value and `rpc_port` still never appears in a prompt or a tool call (#730).
--- @type string[]
local BOUND_VARS = { RpcEnvironment.PORT_VAR, "VIBING_NVIM_CONTEXT" }

--- ACP wants `env` and `headers` as lists of `{ name, value }`, not maps.
--- @param declared table<string, string>|nil
--- @param process_env table<string, string>|nil
--- @return table[]
local function pair_list(declared, process_env)
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
--- @param process_env table<string, string>|nil
--- @return table
local function spec(server, process_env)
  if not server.command then
    return { name = server.name, url = server.url, headers = pair_list(server.headers, nil) }
  end
  return {
    name = server.name,
    command = server.command,
    args = server.args or {},
    env = pair_list(server.env, process_env),
  }
end

--- @class Vibing.CommandCodeMcpResolution
--- @field servers table[] the `mcpServers` list `session/new` takes
--- @field self_server string|nil registered name of the **bundled** server, nil when it is not

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
--- @return Vibing.CommandCodeMcpResolution
function M.resolve(params)
  if params.opts and params.opts.lightweight then
    return { servers = {} }
  end

  -- Matched **by path, not by name**, for the reason `grok_mcp_config` states: with
  -- `integrations.plugins.self = false` a project plugin may carry the name `vibing-nvim`, and
  -- the prompt would then name a tool that the bundled server alone provides.
  local self_dir = PluginDirs.self_plugin_dir()
  local seen, out, self_server = {}, {}, nil
  for _, dir in ipairs(PluginDirs.resolve(params.opts and params.opts.cwd, params.config)) do
    for _, server in ipairs(PluginContents.mcp_servers(dir)) do
      if not seen[server.name] then
        seen[server.name] = true
        table.insert(out, spec(server, params.env))
        if dir == self_dir and not self_server then
          self_server = server.name
        end
      end
    end
  end
  return { servers = out, self_server = self_server }
end

return M
