--- `--permission-prompt-tool`: where claude's own gate sends the questions it would otherwise refuse
--- with nobody to ask.
---
--- Measured on claude 2.1.309. An edit inside a `--plugin-dir` directory is a "sensitive file": the
--- gate asks a human about it, and in `-p` that ask is a refusal. No `permissions.allow` entry,
--- settings allow rule (relative, anchored or absolute) or hook `allow` passes it; only
--- `bypassPermissions` did, and the prompt tool. The answer travels as a native approval
--- (`rpc/handlers/permission_prompt.lua`), so it changes nothing in vibing's own lists.
---
--- **The name must resolve, or the turn dies.** A `--permission-prompt-tool` naming no MCP tool is
--- accepted at startup and fails the turn with exit 1 the first time the gate consults it — not a
--- refusal of that one call. So the flag is passed only when the tool it names is known to exist:
--- the bundled plugin is loaded, its server has been built with this tool in it, and the prefix matches how the server is
--- registered this turn.
---
--- **The same name is put in `--disallowedTools`.** The gate still consults a disallowed tool
--- (measured), and the model can no longer call it, so the only caller is the CLI.
--- @module vibing.infrastructure.adapter.modules.claude_permission_prompt

local CliMcpConfig = require("vibing.infrastructure.adapter.modules.cli_mcp_config")
local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
local Tools = require("vibing.core.constants.tools")

local M = {}

M.TOOL = "nvim_permission_prompt"

local FLAG = "--permission-prompt-tool"

--- Taken from the list `tools_spec.lua` checks against `plugin.json`, so a rename fails a test here
--- instead of naming a tool that does not resolve.
local BARE_PREFIX = (Tools.VIBING_NVIM_MCP_TOOL_PATTERNS[1]):gsub("%*$", "")
local PLUGIN_PREFIX = (Tools.VIBING_NVIM_MCP_TOOL_PATTERNS[2]):gsub("%*$", "")

--- `index.js` alone is not enough: a build from before the tool existed has one too, and passing the
--- flag against it is the dead turn this module exists to prevent.
local BUILT_FILES = { "mcp-server/dist/index.js", "mcp-server/dist/handlers/permission.js" }

--- @param ctx Vibing.RequestContext
--- @return boolean
local function bundled_server_present(ctx)
  local own = PluginDirs.self_plugin_dir()
  if not own then
    return false
  end
  if not vim.tbl_contains(PluginDirs.resolve(ctx.opts.cwd, ctx.config), own) then
    return false
  end
  for _, file in ipairs(BUILT_FILES) do
    if vim.fn.filereadable(own .. "/" .. file) ~= 1 then
      return false
    end
  end
  return true
end

--- The full tool name to hand the CLI this turn, or nil when the flag must not be passed.
--- @param ctx Vibing.RequestContext
--- @return string|nil
local function resolve(ctx)
  local descriptor = require("vibing.infrastructure.adapter.backends.claude")
  if
    not require("vibing.infrastructure.hooks.wait_budget").can_wait_for_native_approval(descriptor.native_approval)
  then
    return nil
  end
  if not bundled_server_present(ctx) then
    return nil
  end
  local prefix = CliMcpConfig.user_servers_enabled(ctx.config) and PLUGIN_PREFIX or BARE_PREFIX
  return prefix .. M.TOOL
end

--- Resolved once per argv build and kept on `ctx`: `--disallowedTools` and the flag itself both ask,
--- and two answers taken a stat apart could pass the flag without the matching disallow entry.
--- @param ctx Vibing.RequestContext
--- @return string|nil
function M.tool_name(ctx)
  if ctx._permission_prompt_tool == nil then
    ctx._permission_prompt_tool = resolve(ctx) or false
  end
  return ctx._permission_prompt_tool or nil
end

--- @param ctx Vibing.RequestContext
--- @return string[]
function M.args(ctx)
  local name = M.tool_name(ctx)
  return name and { FLAG, name } or {}
end

--- The prompt tool a built argv names, or nil. Read off the argv rather than recomputed, because
--- what the process was actually spawned with is the question the handler asks.
--- @param argv string[]
--- @return string|nil
function M.named_in(argv)
  for index, arg in ipairs(argv or {}) do
    if arg == FLAG then
      return argv[index + 1]
    end
  end
  return nil
end

return M
