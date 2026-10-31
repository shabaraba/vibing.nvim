--- A shell reached through a vibing-nvim MCP tool rather than the Bash tool: `nvim_execute` of
--- a shell Ex command (`shell_command`) and every `nvim_job_start` (`job_command`). Both are
--- judged as `Bash` by `can_use_tool`.
---
--- @module vibing.infrastructure.permissions.embedded_shell

local job_command = require("vibing.infrastructure.permissions.job_command")
local shell_command = require("vibing.infrastructure.permissions.shell_command")

local M = {}

local SHELL_OPERATORS = "[;&|`$<>%%#!\n\r]"

--- @class EmbeddedShell
--- @field kind "job"|"ex" a job's backgrounding is decided from its argv, not the joined line
--- @field command string the text the Bash matchers see

--- @param tool_name string
--- @param input table
--- @param is_vibing_tool fun(tool_name: string, specific_tool: string): boolean
--- @return EmbeddedShell|nil
function M.detect(tool_name, input, is_vibing_tool)
  if is_vibing_tool(tool_name, "nvim_job_start") then
    return { kind = "job", command = job_command.from_job(input) }
  end
  if is_vibing_tool(tool_name, "nvim_execute") then
    local command = shell_command.from_ex(input.command)
    if command then
      return { kind = "ex", command = command }
    end
  end
  return nil
end

--- A `Bash(prefix:*)` rule reads only the first words. For the Bash tool the CLI's own allowlist
--- still judges the whole line after vibing answers `defer`; an MCP tool is answered `allow` and
--- nothing checks it again, so `:!npm test; curl … | sh` must not ride on `Bash(npm:*)`. Vim also
--- expands `%`, `#` and `!` in a `:!` line. Only a grant of all of Bash keeps such a line allowed.
--- @param shell EmbeddedShell
--- @param config PermissionConfig
--- @return boolean
function M.allow_needs_review(shell, config)
  if shell.kind ~= "ex" or not shell.command:find(SHELL_OPERATORS) then
    return false
  end
  if config.permission_mode == "auto" or #(config.allowed_tools or {}) == 0 then
    return false
  end
  for _, list in ipairs({ config.allowed_tools, config.session_allowed_tools or {} }) do
    for _, item in ipairs(list) do
      if item:gsub(":once$", "") == "Bash" then
        return false
      end
    end
  end
  return true
end

--- @param tool_name string
--- @param shell EmbeddedShell
--- @param result CanUseToolResult
--- @return CanUseToolResult
function M.annotate(tool_name, shell, result)
  if result.behavior ~= "deny" then
    return { behavior = result.behavior }
  end
  local label = tool_name:match("(nvim_job_start)$") or tool_name:match("(nvim_execute)$") or tool_name
  local preview = shell.command:gsub("%s+", " ")
  if #preview > 120 then
    preview = preview:sub(1, 117) .. "..."
  end
  local message = result.message
  if message and not message:find(label, 1, true) then
    message = string.format("%s runs a shell command (%s) and follows the Bash permission rules. %s", label, preview, message)
  end
  return { behavior = "deny", message = message }
end

return M
