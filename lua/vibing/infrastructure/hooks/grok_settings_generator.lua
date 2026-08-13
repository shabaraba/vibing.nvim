--- Grok Build CLI hook settings generator
--- Writes a project-scoped PreToolUse hook under <cwd>/.grok/hooks/ so vibing's
--- pre-tool-use.sh participates in Grok's permission pipeline (Tool Approval UI).
--- @module vibing.infrastructure.hooks.grok_settings_generator

local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")

local M = {}

local HOOK_FILENAME = "vibing-nvim-pre-tool-use.json"

--- cwds already confirmed trusted this session — folder trust is idempotent, so once a cwd is
--- known-trusted there's no need to re-read/re-scan ~/.grok/trusted_folders.toml on every message.
--- @type table<string, boolean>
local trusted_cwds = {}

--- Absolute path to the generated hook JSON for a given cwd
--- Resolved, so this reports the same path `ensure()` writes -- that one resolves the cwd, and a
--- symlinked working directory would otherwise make the two disagree.
--- @param cwd string
--- @return string
function M.hook_file_path(cwd)
  return vim.fn.resolve(cwd) .. "/.grok/hooks/" .. HOOK_FILENAME
end

--- Escape a string for a TOML basic string (the `folders."<path>"` key).
--- A path is not arbitrary text, but `"` and `\` are both legal in POSIX filenames and either one
--- would break the file's structure -- and this file is grok's, not ours, so corrupting it takes
--- out the user's other trusted folders too. Everything else here is written through vim.json.
--- @param s string
--- @return string
function M._toml_escape(s)
  return (
    s:gsub("\\", "\\\\")
      :gsub('"', '\\"')
      :gsub("\n", "\\n")
      :gsub("\r", "\\r")
      :gsub("\t", "\\t")
  )
end

--- Grok's config directory. `$GROK_HOME` is Grok's own documented override of `~/.grok`, so
--- honouring it is both correct for users who set it and the seam the specs need: folder trust
--- cascades to subdirectories and is never expired, so a spec writing throwaway `tempname()`
--- paths into the real file would keep granting trust that outlives the test run.
--- @return string
local function grok_home()
  local override = vim.env.GROK_HOME
  if override and override ~= "" then
    return override
  end
  return vim.fn.expand("~/.grok")
end

--- Ensure the session cwd is marked trusted in <grok home>/trusted_folders.toml
--- Project hooks are silently skipped without folder trust. Cascades to subdirs.
--- @param cwd string
local function ensure_folder_trust(cwd)
  local real = vim.fn.resolve(cwd)
  if real == "" or real == "/" or real == vim.fn.expand("~") then
    return
  end
  if trusted_cwds[real] then
    return
  end

  local trust_path = grok_home() .. "/trusted_folders.toml"
  vim.fn.mkdir(vim.fn.fnamemodify(trust_path, ":h"), "p")

  local existing = ""
  local rf = io.open(trust_path, "r")
  if rf then
    existing = rf:read("*a") or ""
    rf:close()
  end

  local key = M._toml_escape(real)
  local marker = 'folders."' .. key .. '"'
  if not existing:find(marker, 1, true) then
    local entry = string.format('\n[folders."%s"]\ntrusted = true\ndecided_at = %d\n', key, os.time())
    -- Appended rather than rewritten on purpose: grok writes this same file itself (`/hooks-trust`),
    -- and a read-modify-write would clobber whatever it added in between. A small append is atomic
    -- on POSIX, so the remaining race is two Neovims first touching the *same new* cwd at once and
    -- both appending the key -- which grok's TOML parser would reject as a duplicate. Narrow enough
    -- to accept; rewriting the file would trade it for a worse one.
    local wf = io.open(trust_path, "a")
    if wf then
      wf:write(entry)
      wf:close()
    end
  end

  trusted_cwds[real] = true
end

--- cwds already warned about this session, so a non-git worktree does not notify on every message.
--- @type table<string, boolean>
local warned_non_git = {}

--- Grok discovers `.grok/hooks/` only inside a git repository -- verified with `grok inspect`,
--- which lists the project hook under "Hooks" after `git init` and omits it before. Outside one
--- the hook file is written and then never read, which would silently mean every tool is allowed.
--- @param cwd string
local function warn_if_not_git(cwd)
  if warned_non_git[cwd] then
    return
  end
  if #vim.fs.find(".git", { path = cwd, upward = true }) > 0 then
    return
  end

  warned_non_git[cwd] = true
  vim.notify(
    string.format(
      "[vibing:grok] %s is not inside a git repository. Grok ignores .grok/hooks/ there, so "
        .. "permission rules and the Tool Approval UI will not apply to this session.",
      cwd
    ),
    vim.log.levels.WARN
  )
end

--- Ensure project PreToolUse hook file exists for the given cwd
--- @param cwd? string Working directory (defaults to vim.fn.getcwd())
--- @return string path Absolute path to the hook JSON file
function M.ensure(cwd)
  cwd = cwd or vim.fn.getcwd()
  local real_cwd = vim.fn.resolve(cwd)
  warn_if_not_git(real_cwd)
  local hooks_dir = real_cwd .. "/.grok/hooks"
  local hook_path = hooks_dir .. "/" .. HOOK_FILENAME

  vim.fn.mkdir(hooks_dir, "p")

  -- Grok resolves relative command paths against the hook JSON file directory
  -- (.grok/hooks/), not the project root — so a relative plugin path would miss
  -- bin/hooks/pre-tool-use.sh. Always write an absolute path.
  local hook_script = vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p")
  local settings = SettingsGenerator.generate(hook_script)

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
