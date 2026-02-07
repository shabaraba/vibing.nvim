---@class Vibing.Infrastructure.RipgrepCommandFinder : Vibing.Infrastructure.FileFinder
---Fast file search using ripgrep (rg --files)
---Features: parallel processing, .gitignore support, very fast

local Base = require("vibing.infrastructure.file_finder.base")

local RipgrepCommand = setmetatable({}, { __index = Base })
RipgrepCommand.__index = RipgrepCommand

---Create a RipgrepCommandFinder instance
---@param opts? {mtime_days?: number} Options for finder
---@return Vibing.Infrastructure.RipgrepCommandFinder
function RipgrepCommand:new(opts)
  local instance = setmetatable({}, self)
  instance.name = "ripgrep_command"
  instance.mtime_days = opts and opts.mtime_days
  return instance
end

---Check if rg command is available
---@return boolean
function RipgrepCommand:supports_platform()
  local result = vim.system({ "which", "rg" }, { text = true }):wait()
  return result.code == 0
end

---Search for files using ripgrep command
---@param directory string Target directory to search
---@param pattern string File pattern (e.g., "*.md")
---@return string[] files Array of absolute paths to matched files
---@return string? error Error message (only on failure)
function RipgrepCommand:find(directory, pattern)
  if vim.fn.isdirectory(directory) ~= 1 then
    return {}, "Directory does not exist: " .. directory
  end

  local expanded_dir = vim.fn.expand(directory)

  -- Build rg command
  -- --files: list files instead of searching content
  -- --glob: filter by glob pattern
  -- --no-ignore: don't respect .gitignore (we want all chat files)
  -- --follow: don't follow symlinks
  local cmd = {
    "rg",
    "--files",
    "--glob", pattern,
    "--no-ignore",
    "--no-follow",
    expanded_dir,
  }

  local result = vim.system(cmd, { text = true }):wait()

  -- rg returns 1 when no matches found (not an error)
  if result.code ~= 0 and result.code ~= 1 then
    return {}, "rg command failed: " .. (result.stderr or "unknown error")
  end

  local files = {}
  if result.stdout and result.stdout ~= "" then
    for line in result.stdout:gmatch("[^\r\n]+") do
      if line ~= "" then
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

return RipgrepCommand
