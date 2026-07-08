--- Codex hook settings generator
--- Provides -c arguments to inject PreToolUse hook into `codex exec`
--- Reuses the same pre-tool-use.sh script as the Claude adapter
--- @module vibing.infrastructure.hooks.codex_settings_generator

local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")

local M = {}

--- Get -c arguments for injecting the PreToolUse hook into `codex exec`
--- @return string[] Two-element array: {"-c", "hooks.pre_tool_use=[...]"}
function M.get_hook_args()
  local hook_script = SettingsGenerator.get_hook_script_path()
  local escaped = hook_script:gsub("\\", "\\\\"):gsub('"', '\\"')
  return {
    "-c",
    string.format('hooks.pre_tool_use=[{command="%s",timeout=120}]', escaped),
  }
end

return M
