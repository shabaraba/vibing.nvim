--- Hook settings generator
--- Writes hook settings to .vibing/hook-settings.json for --settings flag
--- @module vibing.infrastructure.hooks.settings_generator

local Fs = require("vibing.core.utils.fs")

local M = {}

--- Resolve a bundled hook script by file name
--- @param name string File name under bin/hooks/
--- @return string
local function hook_script_path(name)
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fn.fnamemodify(source, ":h:h:h:h:h")
  return plugin_root .. "/bin/hooks/" .. name
end

--- Get the path to the PreToolUse hook script
--- @return string
function M.get_hook_script_path()
  return hook_script_path("pre-tool-use.sh")
end

--- Get the path to the StopFailure hook script
--- @return string
function M.get_stop_failure_script_path()
  return hook_script_path("stop-failure.sh")
end

--- Generate settings table with hook configuration
--- @param hook_script_path? string Override for the PreToolUse script path. Grok resolves a
---   relative hook command against its own .grok/hooks/ file rather than the project root, so it
---   has to pass an absolute path it computed itself.
--- @return table
function M.generate(hook_script_path)
  local pre_tool_use_script = hook_script_path or M.get_hook_script_path()

  return {
    hooks = {
      PreToolUse = {
        {
          matcher = ".*",
          hooks = {
            {
              type = "command",
              command = pre_tool_use_script,
              timeout = 120,
            },
          },
        },
      },
      -- StopFailure fires when a turn dies from an API error. The matcher filters on error type,
      -- and only rate_limit is actionable — the rest (overloaded, billing_error, ...) have no
      -- reset time to wait for. The hook cannot block or alter anything; it exists purely so the
      -- auto-resume scheduler learns the turn died rather than completed.
      StopFailure = {
        {
          matcher = "rate_limit",
          hooks = {
            {
              type = "command",
              command = M.get_stop_failure_script_path(),
              timeout = 10,
            },
          },
        },
      },
    },
  }
end

--- Ensure hook settings file exists in .vibing/ of the given cwd
--- @param cwd? string Working directory (defaults to vim.fn.getcwd())
--- @return string path Absolute path to settings file
function M.ensure(cwd)
  cwd = cwd or vim.fn.getcwd()
  local vibing_dir = cwd .. "/.vibing"
  local settings_path = vibing_dir .. "/hook-settings.json"

  Fs.ensure_dir(vibing_dir)

  -- Always regenerate (hook script path may change after plugin update)
  local settings = M.generate()
  local json = vim.json.encode(settings)

  local f = io.open(settings_path, "w")
  if not f then
    error("Failed to create hook settings file: " .. settings_path)
  end
  f:write(json)
  f:close()

  return settings_path
end

return M
