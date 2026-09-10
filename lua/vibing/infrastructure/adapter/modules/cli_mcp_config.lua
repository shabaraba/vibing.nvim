--- The `--strict-mcp-config` / `--mcp-config` fragment that keeps an ordinary claude turn down to
--- the MCP servers vibing.nvim brought itself (`agent.mcp.user_servers = false`).
---
--- `--setting-sources user,project,local` is what makes the user's own `.claude/commands/`,
--- skills and subagents work inside a chat, and it drags every MCP server in `~/.claude.json`
--- along with them. `--strict-mcp-config` is the CLI's only switch for that, and it is
--- all-or-nothing: measured against claude 2.1.231, it drops the servers a `--plugin-dir` plugin
--- declares too, taking vibing-nvim's own 42 `nvim_*` tools with them. So the fragment is a pair —
--- the strict flag *plus* an explicit re-registration of what each loaded plugin declares.
---
--- Re-registered under its bare manifest name, the server arrives as `mcp__vibing-nvim__<tool>`
--- rather than the plugin form `mcp__plugin_vibing-nvim_vibing-nvim__<tool>`. Both spellings are
--- already covered — `tools.VIBING_NVIM_MCP_TOOL_PATTERNS` lists them, the PreToolUse hook matches
--- on the suffix, and the system prompt names both — so nothing downstream has to know which of
--- the two paths a turn took.
---
--- Measurements, and why this is claude-only, are in
--- `handbook/architecture/plugin-and-commands.md` → "User MCP servers".
--- @module vibing.infrastructure.adapter.modules.cli_mcp_config

local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
local PluginContents = require("vibing.infrastructure.plugins.plugin_contents")

local M = {}

--- One server, in the shape `--mcp-config` takes.
---
--- A remote server is emitted as `type = "http"` because that is the only remote transport a
--- plugin manifest is read for here — `plugin_contents` carries `url` and not `type`, so an `sse`
--- server would be re-registered as http. No manifest in this repo declares one; the day one does,
--- `Vibing.PluginMcpServer` is where the transport has to start being carried.
--- @param server Vibing.PluginMcpServer
--- @return table
local function spec(server)
  if not server.command then
    return { type = "http", url = server.url }
  end
  local out = { command = server.command, args = server.args }
  if next(server.env) then
    out.env = server.env
  end
  return out
end

--- Whether ordinary turns should still load the MCP servers the user configured outside
--- vibing.nvim. Absent config reads as `true`, so a hand-built config table keeps today's
--- behaviour.
--- @param config Vibing.Config
--- @return boolean
local function user_servers_enabled(config)
  local mcp = config.agent and config.agent.mcp
  if type(mcp) ~= "table" then
    return true
  end
  return mcp.user_servers ~= false
end

--- The argv fragment for one non-lightweight claude invocation.
---
--- Empty while `agent.mcp.user_servers` is left at its default, so the flag pair only ever
--- appears for a user who asked for it.
---
--- Server names are deduplicated first-plugin-wins, matching the precedence `--plugin-dir`
--- itself gives a duplicate: a project plugin cannot displace the bundled `vibing-nvim` server
--- by declaring one of its own.
--- @param cwd string|nil the chat's `working_dir`; nil means Neovim's own cwd
--- @param config Vibing.Config
--- @return string[]
function M.args(cwd, config)
  if user_servers_enabled(config) then
    return {}
  end

  local servers = {}
  local any = false
  for _, dir in ipairs(PluginDirs.resolve(cwd, config)) do
    for _, server in ipairs(PluginContents.mcp_servers(dir)) do
      if servers[server.name] == nil then
        servers[server.name] = spec(server)
        any = true
      end
    end
  end

  -- An empty Lua table encodes as `[]`, which the CLI rejects as an mcpServers map. With
  -- `plugins.self = false` and no project plugin there is genuinely nothing to register, and the
  -- turn should still run — with no MCP servers at all, which is what was asked for.
  local encoded = vim.json.encode({ mcpServers = any and servers or vim.empty_dict() })
  return { "--strict-mcp-config", "--mcp-config", encoded }
end

return M
