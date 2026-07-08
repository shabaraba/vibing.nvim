---@class Vibing.Infrastructure.FdCommandFinder : Vibing.Infrastructure.FileFinder
---Fast file search using fd (Rust-based find alternative)
---Features: parallel processing, .gitignore support, faster than find

local Base = require("vibing.infrastructure.file_finder.base")

local FdCommand = setmetatable({}, { __index = Base })
FdCommand.__index = FdCommand

---Detect fd executable name (fd or fdfind on Ubuntu/Debian)
---@return string? executable name or nil if not found
local function detect_fd_executable()
  for _, name in ipairs({ "fd", "fdfind" }) do
    local result = vim.system({ "which", name }, { text = true }):wait()
    if result.code == 0 then
      return name
    end
  end
  return nil
end

---Create a FdCommandFinder instance
---@param opts? {mtime_days?: number} Options for finder
---@return Vibing.Infrastructure.FdCommandFinder
function FdCommand:new(opts)
  local instance = setmetatable({}, self)
  instance.name = "fd_command"
  instance.mtime_days = opts and opts.mtime_days
  instance.executable = detect_fd_executable()
  return instance
end

---Check if fd command is available
---@return boolean
function FdCommand:supports_platform()
  return self.executable ~= nil
end

---Extract extension from glob pattern (e.g., "*.md" -> "md")
---@param pattern string Glob pattern
---@return string? extension Extension without dot, or nil if not a simple extension pattern
local function extract_extension(pattern)
  local ext = pattern:match("^%*%.(.+)$")
  return ext
end

---Search for files using fd command
---@param directory string Target directory to search
---@param pattern string File pattern (e.g., "*.md")
---@return string[] files Array of absolute paths to matched files
---@return string? error Error message (only on failure)
function FdCommand:find(directory, pattern)
  if vim.fn.isdirectory(directory) ~= 1 then
    return {}, "Directory does not exist: " .. directory
  end

  local expanded_dir = vim.fn.expand(directory)

  if not self.executable then
    return {}, "fd command not available"
  end

  -- Build fd command
  -- fd [OPTIONS] [pattern] [path]
  -- -t f: files only
  -- -a: absolute paths
  -- -H: include hidden files/directories (e.g., .vibing/)
  -- --no-ignore: don't respect .gitignore (we want all chat files)
  -- --no-follow: don't follow symlinks (prevents circular reference)
  local cmd = {
    self.executable,
    "-t", "f",
    "-a",
    "-H",
    "--no-ignore",
    "--no-follow",
  }

  -- Use -e for extension patterns (more reliable than regex)
  local ext = extract_extension(pattern)
  if ext then
    table.insert(cmd, "-e")
    table.insert(cmd, ext)
  else
    -- Fallback to regex pattern for complex patterns
    local regex_pattern = pattern:gsub("%.", "\\."):gsub("%*", ".*") .. "$"
    table.insert(cmd, regex_pattern)
  end

  -- Add mtime filter if specified
  -- fd uses --changed-within for recent files
  if self.mtime_days then
    table.insert(cmd, "--changed-within")
    table.insert(cmd, tostring(self.mtime_days) .. "d")
  end

  -- fd requires pattern before path: fd [pattern] [path]
  -- When using -e, use "." as match-all pattern
  if ext then
    table.insert(cmd, ".")
  end

  -- Add search path (must be last for fd)
  table.insert(cmd, expanded_dir)

  local result = vim.system(cmd, { text = true }):wait()

  if result.code ~= 0 then
    return {}, "fd command failed: " .. (result.stderr or "unknown error")
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

return FdCommand
