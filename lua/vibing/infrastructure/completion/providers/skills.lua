---@class Vibing.SkillsProvider
---Provides skill candidates from .claude/skills directories
---@module "vibing.infrastructure.completion.providers.skills"
local M = {}

---@type Vibing.CompletionItem[]?
local _cache = nil

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

---Scan skill directories
---@return Vibing.CompletionItem[]
local function scan_skills()
  local items = {}
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
end

return M
