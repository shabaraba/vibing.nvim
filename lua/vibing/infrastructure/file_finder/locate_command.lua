---@class Vibing.Infrastructure.LocateCommandFinder : Vibing.Infrastructure.FileFinder
---Fast file search using locate/plocate (pre-indexed database search)
---Features: fastest search (uses pre-built index), requires updatedb

local Base = require("vibing.infrastructure.file_finder.base")

local LocateCommand = setmetatable({}, { __index = Base })
LocateCommand.__index = LocateCommand

---Create a LocateCommandFinder instance
---@param opts? {mtime_days?: number} Options for finder
---@return Vibing.Infrastructure.LocateCommandFinder
function LocateCommand:new(opts)
  local instance = setmetatable({}, self)
  instance.name = "locate_command"
  instance.mtime_days = opts and opts.mtime_days
  instance.locate_cmd = nil  -- Will be set in supports_platform
  return instance
end

---Check if locate/plocate command is available
---@return boolean
function LocateCommand:supports_platform()
  -- Prefer plocate (faster implementation)
  local plocate_result = vim.system({ "which", "plocate" }, { text = true }):wait()
  if plocate_result.code == 0 then
    self.locate_cmd = "plocate"
    return true
  end

  -- Fall back to locate
  local locate_result = vim.system({ "which", "locate" }, { text = true }):wait()
  if locate_result.code == 0 then
    self.locate_cmd = "locate"
    return true
  end

  return false
end

---Search for files using locate command
---@param directory string Target directory to search
---@param pattern string File pattern (e.g., "*.md")
---@return string[] files Array of absolute paths to matched files
---@return string? error Error message (only on failure)
function LocateCommand:find(directory, pattern)
  if vim.fn.isdirectory(directory) ~= 1 then
    return {}, "Directory does not exist: " .. directory
  end

  if not self.locate_cmd then
    return {}, "locate command not available"
  end

  local expanded_dir = vim.fn.expand(directory)

  -- Build locate command
  -- -i: case-insensitive (optional, but helpful)
  -- We search for the pattern and filter by directory
  local cmd = {
    self.locate_cmd,
    "-i",
    pattern,
  }

  local result = vim.system(cmd, { text = true }):wait()

  -- locate returns 1 when no matches found (not an error)
  if result.code ~= 0 and result.code ~= 1 then
    return {}, self.locate_cmd .. " command failed: " .. (result.stderr or "unknown error")
  end

  local files = {}
  if result.stdout and result.stdout ~= "" then
    for line in result.stdout:gmatch("[^\r\n]+") do
      -- Filter by directory prefix (locate searches entire system)
      if line ~= "" and vim.startswith(line, expanded_dir) then
        -- If mtime filter is specified, check file modification time
        if self.mtime_days then
          local stat = vim.loop.fs_stat(line)
          if stat then
            local now = os.time()
            local mtime = stat.mtime.sec
            local days_ago = (now - mtime) / (24 * 60 * 60)
            if days_ago <= self.mtime_days then
              table.insert(files, line)
            end
          end
        else
          table.insert(files, line)
        end
      end
    end
  end

  return files, nil
end

return LocateCommand
