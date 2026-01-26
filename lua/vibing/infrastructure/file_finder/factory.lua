---@class Vibing.Infrastructure.FileFinderFactory
---Factory for selecting optimal FileFinder based on platform

local M = {}

local FindCommand = require("vibing.infrastructure.file_finder.find_command")
local ScanDir = require("vibing.infrastructure.file_finder.scandir")

---@type Vibing.Infrastructure.FileFinder?
local cached_finder = nil

---Get optimal FileFinder for current platform
---@param force_fallback? boolean Force use of fallback (scandir) for testing
---@return Vibing.Infrastructure.FileFinder
function M.get_finder(force_fallback)
  if cached_finder and not force_fallback then
    return cached_finder
  end

  if not force_fallback then
    local find_cmd = FindCommand:new()
    if find_cmd:supports_platform() then
      cached_finder = find_cmd
      return cached_finder
    end
  end

  cached_finder = ScanDir:new()
  return cached_finder
end

---Reset cache (for testing)
function M.reset_cache()
  cached_finder = nil
end

---Get name of currently used Finder (for debug/logging)
---@return string? finder_name
function M.get_current_finder_name()
  if cached_finder then
    return cached_finder.name
  end
  return nil
end

return M
