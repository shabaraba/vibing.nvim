--- Grok Build CLI hook settings generator
--- Writes a project-scoped PreToolUse hook under <cwd>/.grok/hooks/ so vibing's
--- pre-tool-use.sh participates in Grok's permission pipeline (Tool Approval UI).
--- @module vibing.infrastructure.hooks.grok_settings_generator

local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")

local M = {}

local HOOK_FILENAME = "vibing-nvim-pre-tool-use.json"

--- Absolute path to the generated hook JSON for a given cwd
--- @param cwd string
--- @return string
function M.hook_file_path(cwd)
  return cwd .. "/.grok/hooks/" .. HOOK_FILENAME
end

--- Ensure the session cwd is marked trusted in ~/.grok/trusted_folders.toml
--- Project hooks are silently skipped without folder trust. Cascades to subdirs.
--- @param cwd string
local function ensure_folder_trust(cwd)
  local real = vim.fn.resolve(cwd)
  if real == "" or real == "/" or real == vim.fn.expand("~") then
    return
  end

  local trust_path = vim.fn.expand("~/.grok/trusted_folders.toml")
  vim.fn.mkdir(vim.fn.fnamemodify(trust_path, ":h"), "p")

  local existing = ""
  local rf = io.open(trust_path, "r")
  if rf then
    existing = rf:read("*a") or ""
    rf:close()
  end

  local marker = 'folders."' .. real .. '"'
  if existing:find(marker, 1, true) then
    return
  end

  local entry = string.format(
    '\n[folders."%s"]\ntrusted = true\ndecided_at = %d\n',
    real,
    os.time()
  )
  local wf = io.open(trust_path, "a")
  if wf then
    wf:write(entry)
    wf:close()
  end
end

--- Ensure project PreToolUse hook file exists for the given cwd
--- @param cwd? string Working directory (defaults to vim.fn.getcwd())
--- @return string path Absolute path to the hook JSON file
function M.ensure(cwd)
  cwd = cwd or vim.fn.getcwd()
  local real_cwd = vim.fn.resolve(cwd)
  local hooks_dir = real_cwd .. "/.grok/hooks"
  local hook_path = hooks_dir .. "/" .. HOOK_FILENAME

  vim.fn.mkdir(hooks_dir, "p")

  -- Grok resolves relative command paths against the hook JSON file directory
  -- (.grok/hooks/), not the project root — so a relative plugin path would miss
  -- bin/hooks/pre-tool-use.sh. Always write an absolute path.
  local hook_script = vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p")
  local settings = {
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

  local json = vim.json.encode(settings)
  local f, err = io.open(hook_path, "w")
  if not f then
    error("Failed to create Grok hook settings file: " .. hook_path .. " (" .. tostring(err) .. ")")
  end
  f:write(json)
  f:close()

  ensure_folder_trust(real_cwd)

  return hook_path
end

return M
