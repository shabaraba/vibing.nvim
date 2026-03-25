--- Hook settings generator
--- Creates temp settings file with pre-tool-use hook for --settings flag
--- @module vibing.infrastructure.hooks.settings_generator

local M = {}

--- Get the path to the hook script
--- @return string
function M.get_hook_script_path()
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fn.fnamemodify(source, ":h:h:h:h:h")
  return plugin_root .. "/bin/hooks/pre-tool-use.sh"
end

--- Generate settings table with hook configuration
--- @return table
function M.generate()
  local hook_script = M.get_hook_script_path()

  return {
    hooks = {
      PreToolUse = {
        {
          matcher = ".*",
          hooks = {
            {
              type = "command",
              command = hook_script,
              timeout = 120,
            },
          },
        },
      },
    },
  }
end

--- Write settings to a temp file for --settings flag
--- Uses /tmp directly to avoid Neovim temp dir lifecycle issues
--- @return string path Path to the generated settings file
function M.write_temp_settings()
  local settings = M.generate()
  local json = vim.json.encode(settings)

  local pid = vim.fn.getpid()
  local settings_path = string.format("/tmp/vibing-hook-settings-%d.json", pid)

  local f = io.open(settings_path, "w")
  if not f then
    error("Failed to create hook settings file: " .. settings_path)
  end
  f:write(json)
  f:close()

  return settings_path
end

return M
