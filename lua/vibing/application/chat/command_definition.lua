--- Where a `/name` written in a chat is defined on disk, so `gd` can open it.
---
--- Four things answer to a `/name` and only two are files: a command file, a skill directory,
--- one of vibing.nvim's own Lua handlers (`/model`) and the claude binary itself
--- (`/code-review`). So `resolve` returning nil and `is_known` returning false are different
--- answers -- "no file" and "not a command" -- and the caller owes a different reply to each.
---
--- **A command is asked of the registry that would expand it.** `commands.lua` writes every
--- scanned command into one map, so its precedence is last-write-wins (plugin over user over
--- project) and that is the file a chat's `/foo` takes. Searching paths here would be a second
--- opinion, and `gd` would open a file the chat does not run.
---
--- **A skill is probed by path, against the chat's own cwd**, because the CLI resolves those and
--- it runs in the chat's `working_dir` -- a worktree included. Nothing here lists what exists;
--- the completion providers own that, and one of them spawns the CLI to find out.
--- @module vibing.application.chat.command_definition

local M = {}

--- `:` is in the set because both of Claude Code's namespaced forms use it -- `<plugin>:<skill>`
--- and `<dir>:<command>`. That also rules `<cfile>` out: unix's default `isfname` has no `:`, so
--- it hands back a name cut in half.
local NAME_PATTERN = "/[%w_%-%.:]+"

--- @return string|nil
local function readable(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  return vim.fn.fnamemodify(path, ":p")
end

--- The `/name` the cursor is inside, or nil. Taken from the line, not the buffer, so the rule is
--- testable without a window.
---
--- Both edges are checked because a path (`/Users/x/y.lua`) and a URL (`https://host/page`) are
--- made of the same characters as a command, and `gd` already means something on the first of
--- those: a token followed by `/` is a path segment, one preceded by a name character is the
--- middle of something longer, and a trailing `.`/`:`/`-` is prose.
--- @param line string
--- @param col integer 1-indexed cursor column
--- @return string|nil
function M.name_on_line(line, col)
  local from = 1
  while true do
    local start_idx, end_idx = line:find(NAME_PATTERN, from)
    -- Matches are disjoint and in order, so the one holding the cursor is the only candidate:
    -- past it there is nothing left to find, and a rejected match is a rejected answer.
    if not start_idx or start_idx > col then
      return nil
    end
    from = end_idx + 1

    if col <= end_idx then
      if
        line:sub(start_idx - 1, start_idx - 1):match("[%w_%-%.:/~]")
        or line:sub(end_idx + 1, end_idx + 1) == "/"
      then
        return nil
      end
      local name = line:sub(start_idx + 1, end_idx):gsub("[%.:%-]+$", "")
      return name:match("%w") and name or nil
    end
  end
end

--- The file a chat's `/name` would actually be expanded from, or nil for a built-in.
--- @return string|nil
local function registered_command(name)
  local entry = require("vibing.application.chat.commands").list_all()[name]
  return entry and entry.file_path or nil
end

--- Skill then command under one `.claude/` directory. A namespaced name is only ever the
--- `commands/<prefix>/<name>.md` subdirectory form here, since a skill cannot be nested.
--- @return string|nil
local function under_claude_dir(dir, prefix, name)
  if prefix then
    return readable(dir .. "/commands/" .. prefix .. "/" .. name .. ".md")
  end
  return readable(dir .. "/skills/" .. name .. "/SKILL.md")
    or readable(dir .. "/commands/" .. name .. ".md")
end

--- @param root {name: string, path: string}
--- @return string|nil
local function in_plugin_root(root, name)
  return readable(root.path .. "/skills/" .. name .. "/SKILL.md")
    or readable(root.path .. "/commands/" .. name .. ".md")
end

--- A SKILL.md may declare a `name` that is not its directory's, and the name the CLI offers --
--- the one the user typed -- is that one. Finding it means reading every SKILL.md of the plugin
--- (0.4ms for the 12 bundled here), so it runs only once the directory guess missed.
--- @param root {name: string, path: string}
--- @return string|nil
local function in_plugin_skill_name(root, name)
  for _, skill in ipairs(require("vibing.infrastructure.plugins.plugin_contents").skills(root.path)) do
    if skill.name == name then
      return skill.path
    end
  end
  return nil
end

--- Shared by every plugin root list: the directory-name guess, then the frontmatter fallback,
--- for whichever root matches `plugin`. Both callers need the fallback -- an installed plugin's
--- SKILL.md can declare a name that differs from its directory just as a `--plugin-dir` one can.
--- @param roots {name: string, path: string}[]
--- @param plugin string|nil restrict to this plugin name
--- @param name string
--- @return string|nil
local function search_plugin_roots(roots, plugin, name)
  for _, root in ipairs(roots) do
    if plugin == nil or root.name == plugin then
      local found = in_plugin_root(root, name) or in_plugin_skill_name(root, name)
      if found then
        return found
      end
    end
  end
  return nil
end

--- Plugins this cwd hands to the CLI with `--plugin-dir`, which is how vibing.nvim's own bundled
--- skills are reached: they are never installed, so no scan of `~/.claude/plugins` finds them.
--- @param plugin string|nil restrict to this plugin name
--- @return string|nil
local function in_plugin_dirs(plugin, name, cwd)
  local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
  local Config = require("vibing.config")

  return search_plugin_roots(PluginDirs.resolve_entries(cwd, Config.get()), plugin, name)
end

--- @param plugin string|nil
--- @return string|nil
local function in_installed_plugins(plugin, name)
  return search_plugin_roots(require("vibing.infrastructure.plugins.installed_plugins").roots(), plugin, name)
end

--- The definition file of `/name`, or nil when what answers to it is not a file.
--- @param name string as typed, without the leading slash
--- @param cwd string|nil the chat's `working_dir`; nil means Neovim's own cwd
--- @return string|nil absolute path
function M.resolve(name, cwd)
  if name == "" then
    return nil
  end
  local root = (cwd and cwd ~= "") and cwd or vim.fn.getcwd(-1, -1)
  local prefix, bare = name:match("^([^:]+):(.+)$")
  local key = bare or name

  -- A registered command is what the chat would expand, so it outranks every path below --
  -- including a same-named skill, which vibing.nvim never reaches: it answers `/name` itself.
  -- Namespaced names are not registered (the scan is one directory deep), so they skip this.
  if not prefix then
    local registered = registered_command(key)
    if registered then
      return registered
    end
  end

  return under_claude_dir(root .. "/.claude", prefix, key)
    or under_claude_dir(vim.fn.expand("~/.claude"), prefix, key)
    or in_plugin_dirs(prefix, key, root)
    or in_installed_plugins(prefix, key)
end

--- Whether `/name` is a command this chat would actually run. Asked only once `resolve` came up
--- empty, to tell a built-in apart from a word that merely looks like a command.
---
--- The CLI's own list is read through `peek_cli_commands`, which never starts a probe: fetching
--- it spawns `claude`, and a keypress on a path fragment must not.
--- @return boolean
function M.is_known(name)
  if require("vibing.application.chat.commands").list_all()[name] then
    return true
  end
  for _, item in ipairs(require("vibing.infrastructure.completion.providers.skills").peek_cli_commands()) do
    if item.word == name then
      return true
    end
  end
  return false
end

return M
