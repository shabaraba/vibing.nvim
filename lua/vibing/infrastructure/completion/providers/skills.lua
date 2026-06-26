---@class Vibing.SkillsProvider
---Provides skill candidates from .claude/skills directories
---@module "vibing.infrastructure.completion.providers.skills"
local M = {}

---@type Vibing.CompletionItem[]?
local _cache = nil

---@type Vibing.CompletionItem[]?
local _bundled_cache = nil

---@type boolean
local _loading = false

---@type integer
local _load_generation = 0

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

---Resolve executable and script path for list-commands
---@return string?, string? executable, script_path (nil if not resolvable)
local function resolve_list_commands()
  local current_file = debug.getinfo(1, "S").source:sub(2)
  local plugin_dir = vim.fs.root(current_file, "package.json")
  if not plugin_dir then
    return nil, nil
  end

  local ok, Config = pcall(require, "vibing.config")
  if not ok then
    return nil, nil
  end

  local config = Config.get()

  -- Always use compiled JS + node for list-commands regardless of dev_mode.
  -- Running list-commands.ts via bun causes the process to hang indefinitely
  -- due to SDK async operations not resolving under bun.
  local script_path = plugin_dir .. "/dist/bin/list-commands.js"
  if vim.fn.filereadable(script_path) ~= 1 then
    return nil, nil
  end

  local configured = config.node and config.node.executable
  local executable
  if configured and configured ~= "auto" then
    executable = configured
  else
    executable = vim.fn.exepath("node")
    if executable == "" then
      executable = "node"
    end
  end

  return executable, script_path
end

---Parse raw JSON output from list-commands into completion items
---@param stdout string
---@return Vibing.CompletionItem[]
local function parse_commands_output(stdout)
  local ok, commands = pcall(vim.fn.json_decode, stdout)
  if not ok or type(commands) ~= "table" then
    return {}
  end

  local items = {}
  for _, cmd in ipairs(commands) do
    if type(cmd) == "table" and type(cmd.name) == "string" and cmd.name ~= "" then
      local description = type(cmd.description) == "string" and cmd.description or ""
      local source = "custom"
      if description:match("%(plugin:") then
        source = "plugin"
      elseif description:match("%(user%)") then
        source = "user"
      elseif description:match("%(project%)") then
        source = "project"
      end

      local detail = source
      if source == "plugin" then
        detail = description:match("%(plugin:([^@%)]+)") or "plugin"
      end

      -- For plugin skills without a namespace (no ":" in name), prepend the plugin name.
      -- Native Claude Code invokes these as "plugin:skill" (e.g. "wt-sessions:start").
      -- Skip if detail looks like a git hash (all hex chars, >= 8 chars).
      local word = cmd.name
      if source == "plugin" and not cmd.name:find(":") then
        local is_hash = detail:match("^[0-9a-f]+$") and #detail >= 8
        if not is_hash then
          word = detail .. ":" .. cmd.name
        end
      end

      table.insert(items, {
        word = word,
        label = "/" .. word,
        kind = "Skill",
        description = description,
        detail = detail,
        source = source,
        filterText = word,
      })
    end
  end
  return items
end

---Start async load of dynamic skills from Agent SDK
---Loads in background; sets _bundled_cache when done and invalidates _cache
local function start_async_load()
  if _loading or _bundled_cache then
    return
  end

  local executable, script_path = resolve_list_commands()
  if not executable or not script_path then
    return
  end

  _loading = true
  local load_generation = _load_generation
  local ok = pcall(function()
    vim.system({ executable, script_path }, {}, vim.schedule_wrap(function(result)
      if load_generation ~= _load_generation then
        return
      end
      _loading = false
      if result.code ~= 0 then
        return
      end
      local items = parse_commands_output(result.stdout or "")
      _bundled_cache = items
      _cache = nil
    end))
  end)
  if not ok then
    _loading = false
  end
end

---Get dynamic skills from Agent SDK (custom commands + plugin skills)
---Returns cached result immediately; starts async load if not yet cached
---@return Vibing.CompletionItem[]
local function get_dynamic_sdk_skills()
  if _bundled_cache then
    return _bundled_cache
  end
  start_async_load()
  return {}
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

  -- Deduplicate by word
  local seen = {}
  local deduped = {}
  for _, item in ipairs(items) do
    if not seen[item.word] then
      seen[item.word] = true
      table.insert(deduped, item)
    end
  end

  table.sort(deduped, function(a, b)
    return a.word < b.word
  end)

  return deduped
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

---Preload dynamic skills in background (call at setup time to warm the cache)
function M.preload()
  start_async_load()
end

---Check if dynamic skills (SDK/plugin skills) are still loading
---Returns true before the first async load completes; false once _bundled_cache is populated
---@return boolean
function M.is_preloading()
  return _loading or _bundled_cache == nil
end

---Clear cache (call when skills change)
function M.clear_cache()
  _load_generation = _load_generation + 1
  _cache = nil
  _bundled_cache = nil
  _loading = false
end

return M
