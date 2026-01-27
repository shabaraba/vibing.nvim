---@class Vibing.Infrastructure.FileFinder
---Abstract base class for file search strategies
---Platform-specific implementations (find_command, scandir) implement this interface
---@field name string Finder implementation name ("find_command", "scandir", etc.)
local FileFinder = {}
FileFinder.__index = FileFinder

---Create a FileFinder instance
---@return Vibing.Infrastructure.FileFinder
function FileFinder:new()
  local instance = setmetatable({}, self)
  instance.name = "base"
  return instance
end

---Recursively search for files in a directory
---Must be implemented by subclass (base class throws error)
---@param directory string Target directory to search
---@param pattern string File pattern (e.g., "*.vibing")
---@return string[] files Array of absolute paths to matched files
---@return string? error Error message (only on failure)
function FileFinder:find(directory, pattern)
  error("find() must be implemented by subclass")
end

---Check if this Finder is available on the current platform
---Must be implemented by subclass (base class returns false)
---@return boolean supported True if supported
function FileFinder:supports_platform()
  return false
end

return FileFinder
