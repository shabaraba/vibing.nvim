--- Hook settings generator
--- Writes hook settings to .vibing/hook-settings.json for --settings flag
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

--- Ensure hook settings file exists in .vibing/ of the given cwd
--- @param cwd? string Working directory (defaults to vim.fn.getcwd())
--- @return string path Relative path to settings file
function M.ensure(cwd)
  cwd = cwd or vim.fn.getcwd()
  local vibing_dir = cwd .. "/.vibing"
  local settings_path = vibing_dir .. "/hook-settings.json"

  vim.fn.mkdir(vibing_dir, "p")

  -- Always regenerate (hook script path may change after plugin update)
  local settings = M.generate()
  local json = vim.json.encode(settings)

  local f = io.open(settings_path, "w")
  if not f then
    error("Failed to create hook settings file: " .. settings_path)
  end
  f:write(json)
  f:close()

  return ".vibing/hook-settings.json"
end

return M
