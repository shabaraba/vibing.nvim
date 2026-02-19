---@class Vibing.Application.DailySummaryCollector

local FileFinderFactory = require("vibing.infrastructure.file_finder.factory")
local SectionParserFactory = require("vibing.infrastructure.section_parser.factory")

local M = {}

---Find all vibing chat files in directory recursively
---@param directory string
---@param opts? {mtime_days?: number, strategy?: Vibing.FileFinderStrategy} Options for file search
---@return string[]
function M.find_vibing_files(directory, opts)
  local finder = FileFinderFactory.get_finder({
    mtime_days = opts and opts.mtime_days,
    strategy = opts and opts.strategy,
  })
  -- Search for both *.vibing and *.md files
  -- (*.md will be the new extension for chat buffers)
  local vibing_files, err1 = finder:find(directory, "*.vibing")
  local md_files, err2 = finder:find(directory, "*.md")

  -- Warn about errors but continue with partial results
  -- If both searches completely failed with no results, return empty
  local has_results = (vibing_files and #vibing_files > 0) or (md_files and #md_files > 0)
  if err1 and err2 and not has_results then
    vim.notify(
      string.format("vibing.nvim: Failed to search directory %s: %s", directory, err1),
      vim.log.levels.WARN
    )
    return {}
  end
  -- Warn about partial errors (permission denied on some subdirectories)
  local partial_err = err1 or err2
  if partial_err and has_results then
    vim.notify(
      string.format("vibing.nvim: Partial error searching directory %s: %s", directory, partial_err),
      vim.log.levels.WARN
    )
  end

  local all_files = vim.list_extend(vibing_files or {}, md_files or {})

  -- Filter .md files to only include vibing chat files (with vibing.nvim: true frontmatter)
  local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
  local filtered_files = {}
  for _, file_path in ipairs(all_files) do
    if file_path:match("%.vibing$") or Frontmatter.is_vibing_chat_file(file_path) then
      table.insert(filtered_files, file_path)
    end
  end

  return filtered_files
end

---@param file_path string
---@return string
local function to_tilde_path(file_path)
  return vim.fn.fnamemodify(file_path, ":p:~")
end

---@param file_path string
---@param target_date string
---@return {user: string, assistant: string, timestamp: string, file: string}[]
function M.collect_messages_from_file(file_path, target_date)
  local parser = SectionParserFactory.get_parser()
  local messages, err = parser:extract_messages(file_path, target_date)

  if err then
    vim.notify(
      string.format("vibing.nvim: Failed to parse file %s: %s", file_path, err),
      vim.log.levels.WARN
    )
    return {}
  end

  return messages
end

---@param dir string
---@param directories table
local function add_directory_if_exists(dir, directories)
  if dir and vim.fn.isdirectory(dir) == 1 then
    for _, existing in ipairs(directories) do
      if existing == dir then
        return
      end
    end
    table.insert(directories, dir)
  end
end

---@param dir string
---@param directories table
local function add_directory_without_duplicate(dir, directories)
  for _, existing in ipairs(directories) do
    if existing == dir then
      return
    end
  end
  table.insert(directories, dir)
end

---Get search directories for daily summary collection
---@param include_all boolean When true, uses search_dirs from config or default directories
---@param config table Configuration table with daily_summary.search_dirs and chat settings
---@return string[] Array of directory paths to search for chat files
---
---Behavior:
---  - When include_all=true and search_dirs is configured:
---    Recursively searches for .vibing/chat directories under each search_dir (up to 5 levels).
---    Example: search_dirs = {"~/workspace"} will find all .vibing/chat in ~/workspace/*/.vibing/chat
---  - When include_all=true and search_dirs is not configured:
---    Uses default directories (project_root/.vibing/chat and user data directory)
---  - When include_all=false:
---    Uses only the current project's save directory
---
---Performance: Excludes node_modules, .git, build, and dist directories from recursive search
function M.get_search_directories(include_all, config)
  local directories = {}
  -- Use git root if available (for worktree support), otherwise use cwd
  local Git = require("vibing.core.utils.git")
  local project_root = Git.get_root() or vim.fn.getcwd()

  if include_all then
    -- Use only search_dirs if configured
    if config.daily_summary and config.daily_summary.search_dirs and #config.daily_summary.search_dirs > 0 then
      for _, dir in ipairs(config.daily_summary.search_dirs) do
        -- Validate: skip invalid values
        if type(dir) ~= "string" or dir == "" then
          vim.notify(
            string.format("vibing.nvim: Invalid search_dir (expected non-empty string, got %s)", type(dir)),
            vim.log.levels.WARN
          )
          goto continue
        end

        -- Expand ~ in path
        local expanded_dir = vim.fn.expand(dir):gsub("/$", "")

        -- Check existence and warn if missing
        if vim.fn.isdirectory(expanded_dir) ~= 1 then
          vim.notify(
            string.format("vibing.nvim: search_dir does not exist: %s", expanded_dir),
            vim.log.levels.WARN
          )
          goto continue
        end

        -- Search for .vibing/chat directories recursively under this directory
        -- This allows search_dirs to contain parent directories (e.g., ~/workspace)
        -- and automatically find all project chat directories
        -- Exclude common large directories to improve performance
        local vibing_dirs = vim.fn.systemlist({
          "find",
          expanded_dir,
          "-type", "d",
          "-name", ".vibing",
          "-maxdepth", "5",
          -- Exclude common large directories
          "-not", "-path", "*/node_modules/*",
          "-not", "-path", "*/.git/*",
          "-not", "-path", "*/build/*",
          "-not", "-path", "*/dist/*",
        })

        if vim.v.shell_error == 0 and #vibing_dirs > 0 then
          for _, vibing_dir in ipairs(vibing_dirs) do
            local chat_dir = vibing_dir .. "/chat"
            add_directory_if_exists(chat_dir, directories)
          end
        elseif vim.v.shell_error ~= 0 then
          -- Log error if find command failed
          vim.notify(
            string.format("vibing.nvim: find command failed for %s (exit code: %d)", expanded_dir, vim.v.shell_error),
            vim.log.levels.WARN
          )
          -- Fallback: treat it as a direct chat directory
          add_directory_if_exists(expanded_dir, directories)
        else
          -- No .vibing subdirectories found, treat it as a direct chat directory
          add_directory_if_exists(expanded_dir, directories)
        end
        ::continue::
      end
    else
      -- Default behavior: search multiple standard directories
      add_directory_if_exists(project_root .. "/.vibing/chat", directories)
      add_directory_if_exists(vim.fn.stdpath("data") .. "/vibing/chats", directories)
      if config.chat and config.chat.save_dir then
        local save_dir = config.chat.save_dir:gsub("/$", "")
        add_directory_if_exists(save_dir, directories)
      end
    end
  else
    local FileManager = require("vibing.presentation.chat.modules.file_manager")
    local save_dir = FileManager.get_save_directory(config.chat or {})
    save_dir = save_dir:gsub("/$", "")
    add_directory_if_exists(save_dir, directories)
  end

  return directories
end

---@param target_date string
---@param include_all boolean
---@param config table
---@return {messages: table[], source_files: string[], total_messages: number}
function M.collect_all_messages(target_date, include_all, config)
  local all_messages = {}
  local source_files = {}

  -- Use mtime filter for large directory searches (reduces files to parse)
  -- Set to 3 days for -all option to find recent files containing today's messages
  local mtime_days = include_all and 3 or nil
  -- Get strategy from config (default: "auto")
  local strategy = config.daily_summary and config.daily_summary.file_finder_strategy or "auto"

  for _, directory in ipairs(M.get_search_directories(include_all, config)) do
    for _, file_path in ipairs(M.find_vibing_files(directory, { mtime_days = mtime_days, strategy = strategy })) do
      local messages = M.collect_messages_from_file(file_path, target_date)
      if #messages > 0 then
        table.insert(source_files, to_tilde_path(file_path))
        vim.list_extend(all_messages, messages)
      end
    end
  end

  table.sort(all_messages, function(a, b)
    return (a.timestamp or "") < (b.timestamp or "")
  end)

  return {
    messages = all_messages,
    source_files = source_files,
    total_messages = #all_messages,
  }
end

return M
