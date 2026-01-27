---@class Vibing.Infrastructure.FileFinderFactory
---Factory for selecting optimal FileFinder based on platform

local M = {}

local FindCommand = require("vibing.infrastructure.file_finder.find_command")
local ScanDir = require("vibing.infrastructure.file_finder.scandir")

---@type Vibing.Infrastructure.FileFinder?
local cached_finder = nil

---@type {prune_dirs?: string[]}?
local cached_opts = nil

---Get optimal FileFinder for current platform
---@param opts? {force_fallback?: boolean, prune_dirs?: string[], mtime_days?: number} Options
---@return Vibing.Infrastructure.FileFinder
function M.get_finder(opts)
  local force_fallback = opts and opts.force_fallback
  local prune_dirs = opts and opts.prune_dirs
  local mtime_days = opts and opts.mtime_days

  -- Return cached finder if no custom options
  if cached_finder and not force_fallback and not prune_dirs and not mtime_days then
    return cached_finder
  end

  -- If custom options specified, create new finder (don't cache)
  if prune_dirs or mtime_days then
    local find_cmd = FindCommand:new({
      prune_dirs = prune_dirs,
      mtime_days = mtime_days,
    })
    if find_cmd:supports_platform() then
      return find_cmd
    end
    return ScanDir:new()
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
