---@class Vibing.Infrastructure.FileFinderFactory
---Factory for selecting optimal FileFinder based on strategy and platform

local M = {}

local FindCommand = require("vibing.infrastructure.file_finder.find_command")
local FdCommand = require("vibing.infrastructure.file_finder.fd_command")
local LocateCommand = require("vibing.infrastructure.file_finder.locate_command")
local RipgrepCommand = require("vibing.infrastructure.file_finder.ripgrep_command")
local ScanDir = require("vibing.infrastructure.file_finder.scandir")

---@type Vibing.Infrastructure.FileFinder?
local cached_finder = nil

---@type Vibing.FileFinderStrategy?
local cached_strategy = nil

---Strategy priority for auto selection (fastest to slowest based on benchmark)
---Note: ripgrep is faster than fd for hidden directory searches like .vibing/
---@type Vibing.FileFinderStrategy[]
local AUTO_PRIORITY = { "ripgrep", "fd", "find", "locate" }

---Create finder instance by strategy name
---@param strategy Vibing.FileFinderStrategy
---@param opts? {mtime_days?: number, prune_dirs?: string[]}
---@return Vibing.Infrastructure.FileFinder?
local function create_finder_by_strategy(strategy, opts)
  if strategy == "fd" then
    return FdCommand:new(opts)
  elseif strategy == "find" then
    return FindCommand:new(opts)
  elseif strategy == "locate" then
    return LocateCommand:new(opts)
  elseif strategy == "ripgrep" then
    return RipgrepCommand:new(opts)
  end
  return nil
end

---Get optimal FileFinder based on strategy
---@param opts? {strategy?: Vibing.FileFinderStrategy, force_fallback?: boolean, prune_dirs?: string[], mtime_days?: number} Options
---@return Vibing.Infrastructure.FileFinder
function M.get_finder(opts)
  local strategy = (opts and opts.strategy) or "auto"
  local force_fallback = opts and opts.force_fallback
  local prune_dirs = opts and opts.prune_dirs
  local mtime_days = opts and opts.mtime_days

  -- Return cached finder if no custom options and same strategy
  if cached_finder
    and cached_strategy == strategy
    and not force_fallback
    and not prune_dirs
    and not mtime_days
  then
    return cached_finder
  end

  local finder_opts = {
    prune_dirs = prune_dirs,
    mtime_days = mtime_days,
  }

  -- If specific strategy requested (not auto)
  if strategy ~= "auto" then
    local finder = create_finder_by_strategy(strategy, finder_opts)
    if finder and finder:supports_platform() then
      -- Cache only if no custom options
      if not prune_dirs and not mtime_days then
        cached_finder = finder
        cached_strategy = strategy
      end
      return finder
    end
    -- Strategy not available, fall through to auto
    vim.notify(
      string.format("vibing.nvim: %s not available, falling back to auto selection", strategy),
      vim.log.levels.WARN
    )
  end

  -- Auto selection: try each strategy in priority order
  if not force_fallback then
    for _, auto_strategy in ipairs(AUTO_PRIORITY) do
      local finder = create_finder_by_strategy(auto_strategy, finder_opts)
      if finder and finder:supports_platform() then
        -- Cache only if no custom options
        if not prune_dirs and not mtime_days then
          cached_finder = finder
          cached_strategy = "auto"
        end
        return finder
      end
    end
  end

  -- Final fallback: Lua scandir (always available)
  local fallback = ScanDir:new()
  if not prune_dirs and not mtime_days then
    cached_finder = fallback
    cached_strategy = "auto"
  end
  return fallback
end

---Reset cache (for testing)
function M.reset_cache()
  cached_finder = nil
  cached_strategy = nil
end

---Get name of currently used Finder (for debug/logging)
---@return string? finder_name
function M.get_current_finder_name()
  if cached_finder then
    return cached_finder.name
  end
  return nil
end

---Get current strategy (for debug/logging)
---@return Vibing.FileFinderStrategy?
function M.get_current_strategy()
  return cached_strategy
end

---Get list of available strategies on current platform
---@return Vibing.FileFinderStrategy[]
function M.get_available_strategies()
  local available = {}
  for _, strategy in ipairs(AUTO_PRIORITY) do
    local finder = create_finder_by_strategy(strategy, {})
    if finder and finder:supports_platform() then
      table.insert(available, strategy)
    end
  end
  return available
end

return M
