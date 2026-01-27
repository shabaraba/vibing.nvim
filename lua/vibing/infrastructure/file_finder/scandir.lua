---@class Vibing.Infrastructure.ScanDirFinder : Vibing.Infrastructure.FileFinder
---Fallback file search using vim.loop.fs_scandir
---Used in environments where find command is unavailable (Windows, etc.)

local Base = require("vibing.infrastructure.file_finder.base")

local ScanDir = setmetatable({}, { __index = Base })
ScanDir.__index = ScanDir

---Create a ScanDirFinder instance
---@return Vibing.Infrastructure.ScanDirFinder
function ScanDir:new()
  local instance = setmetatable({}, self)
  instance.name = "scandir"
  return instance
end

---Always available (vim.loop API available on all platforms)
---@return boolean
function ScanDir:supports_platform()
  return true
end

---Convert glob pattern to Lua pattern
---@param pattern string Glob pattern (e.g., "*.vibing")
---@return string lua_pattern Lua pattern
local function glob_to_lua_pattern(pattern)
  local escaped = pattern:gsub("([%.%+%-%^%$%(%)%%])", "%%%1")
  escaped = escaped:gsub("%*", ".*")
  return escaped .. "$"
end

---Recursively scan directory (with symlink protection)
---@param directory string Target directory
---@param lua_pattern string Lua regex pattern
---@param visited table<string, boolean> Visited directories
---@param files string[] Array to store results
local function scan_recursive(directory, lua_pattern, visited, files)
  if vim.fn.isdirectory(directory) ~= 1 then
    return
  end

  -- Symlink circular reference protection
  local real_path = vim.loop.fs_realpath(directory) or directory
  if visited[real_path] then
    return
  end
  visited[real_path] = true

  local handle = vim.loop.fs_scandir(directory)
  if not handle then
    return
  end

  while true do
    local name, entry_type = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end

    local full_path = directory .. "/" .. name
    if entry_type == "directory" then
      scan_recursive(full_path, lua_pattern, visited, files)
    elseif entry_type == "file" and name:match(lua_pattern) then
      table.insert(files, full_path)
    end
  end
end

---Search for files using fs_scandir
---@param directory string Target directory to search
---@param pattern string File pattern (e.g., "*.vibing")
---@return string[] files Array of absolute paths to matched files
---@return string? error Error message (only on failure)
function ScanDir:find(directory, pattern)
  if vim.fn.isdirectory(directory) ~= 1 then
    return {}, "Directory does not exist: " .. directory
  end

  local lua_pattern = glob_to_lua_pattern(pattern)
  local visited = {}
  local files = {}

  scan_recursive(directory, lua_pattern, visited, files)

  return files, nil
end

return ScanDir
