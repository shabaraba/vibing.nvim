--- The one rule for where a process belongs: the current turn, a Neovim-owned job, or nowhere.
---
--- Every backend gets these lines, on whichever channel it has (Claude's system prompt, Codex's
--- `developer_instructions`, Grok's `--rules`, OpenCode's instruction file, or the prompt prefix
--- the remaining CLIs only have). Where a CLI cannot reach the bundled MCP server the wording
--- says so rather than naming `nvim_job_start`: `handbook/ADAPTER_DEVELOPMENT.md` forbids naming
--- a vibing.nvim MCP tool in a prompt sent to a CLI that cannot invoke it.
---
--- The lines carry no per-chat value, so a backend that keeps them in a cached prefix stays
--- byte-stable across turns (#469).
--- @module vibing.infrastructure.adapter.modules.background_job_instructions

local M = {}

--- Present verbatim in both variants: the conformance suite asserts every backend carries it.
M.MARKER = "vibing.nvim's rule for long-running processes"

--- The common half: what belongs to the turn, and why the near-misses do not work.
local function head()
  return {
    M.MARKER .. ": a command that belongs to this turn (a test, a build, a one-off check) runs in "
      .. "the foreground and is waited on.",
    "A process that must still be running after this turn ends -- a development server, a file "
      .. "watcher, a `--watch` test runner, a log tailer, a queue worker -- is a background job, "
      .. "not a turn step.",
  }
end

--- The shared prohibition, which is the same whether the tool exists or not.
local function tail()
  return {
    "Do not use shell backgrounding such as &, nohup, setsid or disown for such a process, and do "
      .. "not register it with the CLI's own background-task or monitor mechanism. That registry "
      .. "lives inside the CLI process, which vibing.nvim replaces between turns and reclaims "
      .. "after an idle period, so the registration is lost and the process is usually killed "
      .. "with it.",
  }
end

--- The policy lines for one request.
--- @param opts {tool: boolean}|nil `tool` is true only when this request can reach the bundled
---   vibing-nvim MCP server (see `M.reachable`)
--- @return string[]
function M.lines(opts)
  opts = opts or {}
  local lines = head()
  if opts.tool then
    table.insert(
      lines,
      "For such a process you MUST use the vibing-nvim nvim_job_start MCP tool. It is owned by "
        .. "Neovim, survives the turn, and reports its completion in this chat; manage it with "
        .. "nvim_job_status, nvim_job_wait and nvim_job_stop. nvim_job_start follows the same "
        .. "permission rules as Bash."
    )
    vim.list_extend(lines, tail())
    table.insert(lines, "If nvim_job_start is unavailable, say so instead of silently substituting either mechanism.")
  else
    table.insert(
      lines,
      "This session exposes no Neovim-owned job tool, so do not start such a process at all."
    )
    vim.list_extend(lines, tail())
    table.insert(lines, "Say so and stop instead of substituting either mechanism.")
  end
  return lines
end

--- The same lines rendered as a prompt prefix, for a CLI with no instruction channel.
--- @param prompt string
--- @param opts {tool: boolean}|nil
--- @return string
function M.prefix(prompt, opts)
  return table.concat(M.lines(opts), "\n") .. "\n\n" .. prompt
end

--- Whether a request in `cwd` can reach the bundled server.
---
--- Asked of the plugin directories rather than of the CLI, because that is what decides it for
--- every backend: the bundled plugin is offered only while `integrations.plugins.self` is not
--- false, and it is the manifest that declares the server. A CLI with no bundled-server path at
--- all (Copilot, Pi, Grok oneshot) must not call this — it would answer for a server the CLI
--- never receives.
--- @param cwd string|nil
--- @param config Vibing.Config
--- @return boolean
function M.reachable(cwd, config)
  local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
  local PluginContents = require("vibing.infrastructure.plugins.plugin_contents")
  local self_dir = PluginDirs.self_plugin_dir()
  if not self_dir then
    return false
  end
  for _, entry in ipairs(PluginDirs.resolve_entries(cwd, config)) do
    if entry.path == self_dir then
      return #PluginContents.mcp_servers(entry.path) > 0
    end
  end
  return false
end

return M
