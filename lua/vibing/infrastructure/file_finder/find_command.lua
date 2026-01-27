---@class Vibing.Infrastructure.FindCommandFinder : Vibing.Infrastructure.FileFinder
---Fast file search using Unix find command
---Available on macOS/Linux environments

local Base = require("vibing.infrastructure.file_finder.base")

local FindCommand = setmetatable({}, { __index = Base })
FindCommand.__index = FindCommand

-- Default directories to prune for performance (node_modules, .git, etc.)
local DEFAULT_PRUNE_DIRS = {
  "node_modules",
  ".git",
  "vendor",
  ".cache",
  "dist",
  "build",
  ".next",
  "__pycache__",
  ".venv",
  "venv",
}

---Create a FindCommandFinder instance
---@param opts? {prune_dirs?: string[], mtime_days?: number} Options for finder
---@return Vibing.Infrastructure.FindCommandFinder
function FindCommand:new(opts)
  local instance = setmetatable({}, self)
  instance.name = "find_command"
  instance.prune_dirs = (opts and opts.prune_dirs) or DEFAULT_PRUNE_DIRS
  instance.mtime_days = opts and opts.mtime_days  -- nil means no mtime filter
  return instance
end

---Check if find command is available
---@return boolean
function FindCommand:supports_platform()
  local result = vim.system({ "which", "find" }, { text = true }):wait()
  return result.code == 0
end

---Build prune arguments for find command
---@param prune_dirs string[] Directories to prune
---@return string[] args Arguments to add to find command
local function build_prune_args(prune_dirs)
  local args = {}
  -- Build: \( -path '*/node_modules/*' -o -path '*/.git/*' ... \) -prune -o
  if #prune_dirs > 0 then
    table.insert(args, "(")
    for i, dir in ipairs(prune_dirs) do
      if i > 1 then
        table.insert(args, "-o")
      end
      table.insert(args, "-path")
      table.insert(args, "*/" .. dir .. "/*")
    end
    table.insert(args, ")")
    table.insert(args, "-prune")
    table.insert(args, "-o")
  end
  return args
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

  -- Build command with pruning for performance
  -- -P: Do not follow symlinks (prevents circular reference)
  local cmd = { "find", "-P", vim.fn.expand(directory) }

  -- Add prune arguments for large directories
  local prune_args = build_prune_args(self.prune_dirs)
  for _, arg in ipairs(prune_args) do
    table.insert(cmd, arg)
  end

  -- Add file matching criteria
  table.insert(cmd, "-type")
  table.insert(cmd, "f")
  table.insert(cmd, "-name")
  table.insert(cmd, pattern)

  -- Add mtime filter if specified (e.g., -mtime -1 for files modified within 24 hours)
  if self.mtime_days then
    table.insert(cmd, "-mtime")
    table.insert(cmd, "-" .. tostring(self.mtime_days))
  end

  table.insert(cmd, "-print")

  local result = vim.system(cmd, { text = true }):wait()

  -- Any non-zero exit code is an error (permission denied, invalid path, etc.)
  if result.code ~= 0 then
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
