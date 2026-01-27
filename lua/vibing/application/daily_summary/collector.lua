---@class Vibing.Application.DailySummaryCollector

local FileFinderFactory = require("vibing.infrastructure.file_finder.factory")
local SectionParserFactory = require("vibing.infrastructure.section_parser.factory")

local M = {}

---Find all .vibing files in directory recursively
---@param directory string
---@param opts? {mtime_days?: number} Options for file search
---@return string[]
function M.find_vibing_files(directory, opts)
  local finder = FileFinderFactory.get_finder({
    mtime_days = opts and opts.mtime_days,
  })
  local files, err = finder:find(directory, "*.vibing")

  if err then
    vim.notify(
      string.format("vibing.nvim: Failed to search directory %s: %s", directory, err),
      vim.log.levels.WARN
    )
    return {}
  end

  return files
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

---@param include_all boolean
---@param config table
---@return string[]
function M.get_search_directories(include_all, config)
  local directories = {}
  local project_root = vim.fn.getcwd()

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

        -- Already validated existence, only check for duplicates
        add_directory_without_duplicate(expanded_dir, directories)
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
  local mtime_days = include_all and 1 or nil

  for _, directory in ipairs(M.get_search_directories(include_all, config)) do
    for _, file_path in ipairs(M.find_vibing_files(directory, { mtime_days = mtime_days })) do
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
