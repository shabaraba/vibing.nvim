---@class Vibing.Infrastructure.FindCommandFinder : Vibing.Infrastructure.FileFinder
---Fast file search using Unix find command
---Available on macOS/Linux environments

local Base = require("vibing.infrastructure.file_finder.base")

local FindCommand = setmetatable({}, { __index = Base })
FindCommand.__index = FindCommand

---Create a FindCommandFinder instance
---@return Vibing.Infrastructure.FindCommandFinder
function FindCommand:new()
  local instance = setmetatable({}, self)
  instance.name = "find_command"
  return instance
end

---Check if find command is available
---@return boolean
function FindCommand:supports_platform()
  local result = vim.system({ "which", "find" }, { text = true }):wait()
  return result.code == 0
end

---Search for files using find command
---@param directory string Target directory to search
---@param pattern string File pattern (e.g., "*.vibing")
---@return string[] files Array of absolute paths to matched files
---@return string? error Error message (only on failure)
function FindCommand:find(directory, pattern)
  if vim.fn.isdirectory(directory) ~= 1 then
    return {}, "Directory does not exist: " .. directory
  end

  -- -P: Do not follow symlinks (prevents circular reference)
  -- -type f: Regular files only
  -- -name: Pattern matching
  local cmd = {
    "find",
    "-P",
    vim.fn.expand(directory),
    "-type", "f",
    "-name", pattern,
  }

  local result = vim.system(cmd, { text = true }):wait()

  -- code 0: Success
  -- code 1: No files found (acceptable)
  -- others: Error
  if result.code ~= 0 and result.code ~= 1 then
    return {}, "find command failed: " .. (result.stderr or "unknown error")
  end

  local files = {}
  if result.stdout and result.stdout ~= "" then
    for line in result.stdout:gmatch("[^\r\n]+") do
      if line ~= "" then
        table.insert(files, line)
      end
    end
  end

  return files, nil
end

return FindCommand
