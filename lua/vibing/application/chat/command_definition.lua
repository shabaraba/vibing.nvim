--- Where a `/name` written in a chat is defined on disk, so `gd` can open it.
---
--- A slash command reaches a chat from four places and only some of them are files: a skill
--- directory (`skills/<name>/SKILL.md`), a command file (`commands/<name>.md`), one of
--- vibing.nvim's own Lua handlers (`/model`, `/permission`) and the claude binary itself
--- (`/code-review`, `/dataviz`). The last two have nothing to open, which is why `resolve`
--- answering `nil` is not the same question as `is_known` answering `false` -- the first is "no
--- file", the second is "not a command at all", and the caller owes the user a different answer
--- to each.
---
--- Names are resolved by asking whether a specific path exists, never by listing what exists: the
--- completion providers already own "which commands are there" and one of them spawns the CLI to
--- find out. So this costs a handful of `filereadable` calls per keypress, and it answers for the
--- cwd it is handed rather than for whichever directory a provider's cache was warmed in -- a
--- chat attached to a worktree asks about that worktree's `.claude/`.
--- @module vibing.application.chat.command_definition

local M = {}

--- The characters a slash command name is written with. `:` is in the set because both of Claude
--- Code's namespaced forms use it -- a plugin's skill (`<plugin>:<skill>`) and a command in a
--- subdirectory (`<dir>:<command>`). That also means the token cannot be read with `<cfile>`:
--- Neovim's default `isfname` has no `:` on unix, so it hands back a name cut in half.
local NAME_PATTERN = "/[%w_%-%.:]+"

--- @param path string
--- @return string|nil
local function readable(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  return vim.fn.fnamemodify(path, ":p")
end

--- First match of a glob, so a name present in two installed plugins resolves to a stable one.
--- @param pattern string
--- @return string|nil
local function first_match(pattern)
  local found = vim.fn.glob(pattern, false, true)
  table.sort(found)
  return found[1]
end

--- The `/name` the cursor is inside, or nil.
---
--- Read from the line rather than from the buffer so the rule is testable without a window, and
--- deliberately strict about both edges: a path (`/Users/x/y.lua`) and a URL
--- (`https://host/page`) are made of the same characters as a command, and `gd` in a chat has an
--- older meaning on the first of those. A token whose next character is `/` is therefore a path
--- segment, and one whose previous character could belong to a name is the middle of something
--- longer. Trailing `.`/`:`/`-` is prose, not part of the name.
--- @param line string
--- @param col integer 1-indexed cursor column
--- @return string|nil
function M.name_on_line(line, col)
  if type(line) ~= "string" or line == "" then
    return nil
  end

  local from = 1
  while true do
    local start_idx, end_idx = line:find(NAME_PATTERN, from)
    if not start_idx then
      return nil
    end
    from = end_idx + 1

    -- Matches are disjoint and in order, so the one holding the cursor is the only candidate:
    -- a rejected match is a rejected answer, not a reason to keep looking.
    if col >= start_idx and col <= end_idx then
      local before = start_idx > 1 and line:sub(start_idx - 1, start_idx - 1) or ""
      if before:match("[%w_%-%.:/~]") or line:sub(end_idx + 1, end_idx + 1) == "/" then
        return nil
      end
      local name = line:sub(start_idx + 1, end_idx):gsub("[%.:%-]+$", "")
      if name == "" or not name:match("%w") then
        return nil
      end
      return name
    end
  end
end

--- Skill then command, under one `.claude/` directory.
--- @param claude_dir string
--- @param name string
--- @return string|nil
local function under_claude_dir(claude_dir, name)
  return readable(claude_dir .. "/skills/" .. name .. "/SKILL.md")
    or readable(claude_dir .. "/commands/" .. name .. ".md")
end

--- Skills and commands of the plugins this cwd hands to the CLI with `--plugin-dir`, which is how
--- vibing.nvim's own bundled skills are reached: they are never installed, so no scan of
--- `~/.claude/plugins/` can find them.
---
--- Skills go through `plugin_contents` rather than a path guess because a plugin's SKILL.md may
--- declare a `name` that is not its directory's, and the name the CLI offers -- the one the user
--- typed -- is that one.
--- @param plugin string|nil restrict to this plugin name
--- @param name string
--- @param cwd string
--- @return string|nil
local function in_plugin_dirs(plugin, name, cwd)
  local dirs_ok, PluginDirs = pcall(require, "vibing.infrastructure.plugins.plugin_dirs")
  local config_ok, Config = pcall(require, "vibing.config")
  local contents_ok, PluginContents = pcall(require, "vibing.infrastructure.plugins.plugin_contents")
  if not (dirs_ok and config_ok and contents_ok) then
    return nil
  end

  for _, entry in ipairs(PluginDirs.resolve_entries(cwd, Config.get())) do
    if plugin == nil or entry.name == plugin then
      for _, skill in ipairs(PluginContents.skills(entry.path)) do
        if skill.name == name then
          return skill.path
        end
      end
      local command = readable(entry.path .. "/commands/" .. name .. ".md")
      if command then
        return command
      end
    end
  end
  return nil
end

--- A skill or command of an installed plugin. Two layouts, both of them Claude Code's own:
--- `marketplaces/<market>/plugins/<plugin>/` and `cache/<market>/<plugin>/<revision>/`.
--- @param plugin string|nil
--- @param name string
--- @return string|nil
local function in_installed_plugins(plugin, name)
  local root = vim.fn.expand("~/.claude/plugins")
  local plugin_roots = {
    string.format("%s/marketplaces/*/plugins/%s", root, plugin or "*"),
    string.format("%s/cache/*/%s/*", root, plugin or "*"),
  }
  for _, plugin_root in ipairs(plugin_roots) do
    local found = first_match(plugin_root .. "/skills/" .. name .. "/SKILL.md")
      or first_match(plugin_root .. "/commands/" .. name .. ".md")
    if found then
      return found
    end
  end
  return nil
end

--- A `<prefix>:<name>` is either a plugin's skill or a command in a `commands/<prefix>/`
--- subdirectory -- Claude Code's two namespaced forms, written identically.
--- @param prefix string
--- @param name string
--- @param cwd string
--- @return string|nil
local function namespaced_definition(prefix, name, cwd)
  return in_plugin_dirs(prefix, name, cwd)
    or in_installed_plugins(prefix, name)
    or readable(cwd .. "/.claude/commands/" .. prefix .. "/" .. name .. ".md")
    or readable(vim.fn.expand("~/.claude/commands/") .. prefix .. "/" .. name .. ".md")
end

--- The definition file of `/name`, in the order Claude Code itself resolves one: project, then
--- user, then plugin.
--- @param name string as typed, without the leading slash
--- @param cwd string|nil the chat's `working_dir`; nil means Neovim's own cwd
--- @return string|nil absolute path
function M.resolve(name, cwd)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local root = (cwd and cwd ~= "") and cwd or vim.fn.getcwd(-1, -1)
  root = (vim.fn.fnamemodify(root, ":p"):gsub("/$", ""))

  local prefix, bare = name:match("^([^:]+):(.+)$")
  if prefix then
    return namespaced_definition(prefix, bare, root)
  end

  return under_claude_dir(root .. "/.claude", name)
    or under_claude_dir(vim.fn.expand("~/.claude"), name)
    or in_plugin_dirs(nil, name, root)
    or in_installed_plugins(nil, name)
end

--- Whether `/name` is a command this chat would actually run.
---
--- Asked only after `resolve` came up empty, to tell a built-in apart from a word that merely
--- looks like a command. The CLI's list is consulted **only while it is already cached**: the
--- provider fetches it by spawning `claude`, and a keypress on a path fragment must not pay for
--- that.
--- @param name string
--- @return boolean
function M.is_known(name)
  local commands_ok, Commands = pcall(require, "vibing.application.chat.commands")
  if commands_ok and Commands.list_all()[name] then
    return true
  end

  local skills_ok, Skills = pcall(require, "vibing.infrastructure.completion.providers.skills")
  if not skills_ok or Skills.is_preloading() then
    return false
  end
  for _, item in ipairs(Skills.get_all()) do
    if item.word == name then
      return true
    end
  end
  return false
end

return M
