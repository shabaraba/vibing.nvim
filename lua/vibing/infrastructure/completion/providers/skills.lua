---@class Vibing.SkillsProvider
---Provides skill candidates from .claude/skills directories
---@module "vibing.infrastructure.completion.providers.skills"
local M = {}

---@type Vibing.CompletionItem[]?
local _cache = nil

---@type Vibing.CompletionItem[]?
local _bundled_cache = nil

---Parse SKILL.md to extract name and description
---@param file_path string
---@return {name: string, description: string}?
local function parse_skill(file_path)
  if vim.fn.filereadable(file_path) ~= 1 then
    return nil
  end

  local lines = vim.fn.readfile(file_path, "", 50)
  if not lines or #lines == 0 then
    return nil
  end

  local dir_name = vim.fn.fnamemodify(vim.fn.fnamemodify(file_path, ":h"), ":t")
  local description = dir_name

  for _, line in ipairs(lines) do
    local match = line:match("^#%s+(.+)$")
    if match then
      description = match
      break
    end
  end

  return { name = dir_name, description = description }
end

---Get hardcoded bundled skills (Claude Code built-in skills)
---These are not available via supportedCommands() API
---@return Vibing.CompletionItem[]
local function get_hardcoded_bundled_skills()
  return {
    {
      word = "simplify",
      label = "/simplify",
      kind = "Skill",
      description = "Reviews recently changed files for code reuse, quality, and efficiency issues, then fixes them",
      detail = "bundled",
      source = "bundled",
      filterText = "simplify",
    },
    {
      word = "batch",
      label = "/batch",
      kind = "Skill",
      description = "Orchestrates large-scale changes across a codebase in parallel",
      detail = "bundled",
      source = "bundled",
      filterText = "batch",
    },
    {
      word = "debug",
      label = "/debug",
      kind = "Skill",
      description = "Troubleshoots your current Claude Code session by reading the session debug log",
      detail = "bundled",
      source = "bundled",
      filterText = "debug",
    },
    {
      word = "claude-api",
      label = "/claude-api",
      kind = "Skill",
      description = "Loads Claude API reference material for your project's language",
      detail = "bundled",
      source = "bundled",
      filterText = "claude-api",
    },
  }
end

---Get dynamic skills from Agent SDK (custom commands + plugin skills)
---@return Vibing.CompletionItem[]
local function get_dynamic_sdk_skills()
  if _bundled_cache then
    return _bundled_cache
  end

  -- Find the plugin directory
  local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
  local list_commands_script = plugin_dir .. "/bin/list-commands.ts"

  -- Check if we should use TypeScript directly (dev mode) or compiled JS
  local ok, config = pcall(require, "vibing.config")
  if not ok then
    -- Config not loaded, use defaults
    return {}
  end

  local executable = config.node and config.node.executable or "node"
  local dev_mode = config.node and config.node.dev_mode or false
  local script_path = list_commands_script

  if not dev_mode then
    -- Production mode: use compiled JS
    script_path = plugin_dir .. "/dist/bin/list-commands.js"
    if vim.fn.filereadable(script_path) ~= 1 then
      -- Fallback to empty list if compiled version doesn't exist
      return {}
    end
  end

  -- Execute the script to get SDK-provided skills
  local cmd = { executable, script_path }
  local result = vim.fn.systemlist(cmd)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    return {}
  end

  -- Parse JSON output
  local ok, commands = pcall(vim.fn.json_decode, table.concat(result, "\n"))
  if not ok or type(commands) ~= "table" then
    return {}
  end

  -- Convert to completion items
  local items = {}
  for _, cmd in ipairs(commands) do
    if cmd.name then
      -- Determine source based on description suffix
      local source = "custom"
      if cmd.description and cmd.description:match("%(plugin:") then
        source = "plugin"
      elseif cmd.description and cmd.description:match("%(user%)") then
        source = "user"
      elseif cmd.description and cmd.description:match("%(project%)") then
        source = "project"
      end

      table.insert(items, {
        word = cmd.name,
        label = "/" .. cmd.name,
        kind = "Skill",
        description = cmd.description or "",
        detail = source,
        source = source,
        filterText = cmd.name,
      })
    end
  end

  _bundled_cache = items
  return items
end

---Get all bundled skills (hardcoded + dynamic SDK skills)
---@return Vibing.CompletionItem[]
local function get_bundled_skills()
  local hardcoded = get_hardcoded_bundled_skills()
  local dynamic = get_dynamic_sdk_skills()

  -- Merge without duplicates
  local seen = {}
  local merged = {}

  for _, item in ipairs(hardcoded) do
    seen[item.word] = true
    table.insert(merged, item)
  end

  for _, item in ipairs(dynamic) do
    if not seen[item.word] then
      table.insert(merged, item)
    end
  end

  return merged
end

---Scan skill directories
---@return Vibing.CompletionItem[]
local function scan_skills()
  local items = {}

  -- Add bundled skills first
  for _, skill in ipairs(get_bundled_skills()) do
    table.insert(items, skill)
  end

  -- Scan local skill directories
  local dirs = M.scan_directories()

  for _, dir_info in ipairs(dirs) do
    if vim.fn.isdirectory(dir_info.dir) == 1 then
      local skill_dirs = vim.fn.glob(dir_info.dir .. "*/", false, true)
      for _, skill_dir in ipairs(skill_dirs) do
        local skill_file = skill_dir .. "SKILL.md"
        local skill = parse_skill(skill_file)
        if skill then
          table.insert(items, {
            word = skill.name,
            label = "/" .. skill.name,
            kind = "Skill",
            description = skill.description,
            detail = dir_info.source,
            source = dir_info.source,
            filterText = skill.name,
          })
        end
      end
    end
  end

  table.sort(items, function(a, b)
    return a.word < b.word
  end)

  return items
end

---Define directories to scan for skills
---@return {dir: string, source: "project"|"user"}[]
function M.scan_directories()
  return {
    { dir = vim.fn.getcwd() .. "/.claude/skills/", source = "project" },
    { dir = vim.fn.expand("~/.claude/skills/"), source = "user" },
  }
end

---Get all skill candidates (cached)
---@return Vibing.CompletionItem[]
function M.get_all()
  if not _cache then
    _cache = scan_skills()
  end
  return _cache
end

---Clear cache (call when skills change)
function M.clear_cache()
  _cache = nil
  _bundled_cache = nil
end

return M
