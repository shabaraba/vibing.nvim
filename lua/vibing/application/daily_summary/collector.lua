---@class Vibing.Application.DailySummaryCollector

local Timestamp = require("vibing.core.utils.timestamp")

local M = {}

---@param directory string
---@return string[]
function M.find_vibing_files(directory)
  local files = {}
  if vim.fn.isdirectory(directory) ~= 1 then
    return files
  end

  local handle = vim.loop.fs_scandir(directory)
  if not handle then
    return files
  end

  while true do
    local name, entry_type = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end

    local full_path = directory .. "/" .. name
    if entry_type == "directory" then
      vim.list_extend(files, M.find_vibing_files(full_path))
    elseif entry_type == "file" and name:match("%.vibing$") then
      table.insert(files, full_path)
    end
  end

  return files
end

---@param lines string[]
---@return {role: string, header: string, lines: string[]}[]
local function extract_all_sections(lines)
  local sections = {}
  local current_section = nil

  for _, line in ipairs(lines) do
    local role = Timestamp.extract_role(line)
    if role == "user" or role == "assistant" then
      if current_section then
        table.insert(sections, current_section)
      end
      current_section = { role = role, header = line, lines = {} }
    elseif current_section and not line:match("^---") and not line:match("^Context:") then
      table.insert(current_section.lines, line)
    end
  end

  if current_section then
    table.insert(sections, current_section)
  end
  return sections
end

---@param file_path string
---@return string
local function to_tilde_path(file_path)
  return vim.fn.fnamemodify(file_path, ":p:~")
end

---@param file_path string
---@return string|nil content
local function read_file_content(file_path)
  local file = io.open(file_path, "r")
  if not file then
    return nil
  end

  local content = file:read("*all")
  file:close()

  if not content or content == "" then
    return nil
  end

  return content
end

---@param file_path string
---@param target_date string
---@return {user: string, assistant: string, timestamp: string, file: string}[]
function M.collect_messages_from_file(file_path, target_date)
  local content = read_file_content(file_path)
  if not content then
    return {}
  end

  local lines = vim.split(content, "\n")
  local sections = extract_all_sections(lines)
  local normalized_path = to_tilde_path(file_path)

  local messages = {}
  for i, section in ipairs(sections) do
    if section.role == "user" then
      local timestamp = Timestamp.extract_timestamp_from_comment(section.header)
      if timestamp and timestamp:sub(1, 10) == target_date then
        local next_section = sections[i + 1]
        local assistant_content = ""
        if next_section and next_section.role == "assistant" then
          assistant_content = table.concat(next_section.lines, "\n")
        end

        table.insert(messages, {
          user = table.concat(section.lines, "\n"),
          assistant = assistant_content,
          timestamp = timestamp,
          file = normalized_path,
        })
      end
    end
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

---@param include_all boolean
---@param config table
---@return string[]
function M.get_search_directories(include_all, config)
  local directories = {}
  local project_root = vim.fn.getcwd()

  if include_all then
    -- search_dirsが設定されている場合はそのリストのみを使用
    if config.daily_summary and config.daily_summary.search_dirs and #config.daily_summary.search_dirs > 0 then
      for _, dir in ipairs(config.daily_summary.search_dirs) do
        -- バリデーション: 無効な値をスキップ
        if type(dir) ~= "string" or dir == "" then
          vim.notify(
            string.format("vibing.nvim: Invalid search_dir (expected non-empty string, got %s)", type(dir)),
            vim.log.levels.WARN
          )
          goto continue
        end

        -- ~を展開
        local expanded_dir = vim.fn.expand(dir):gsub("/$", "")

        -- 存在確認と警告
        if vim.fn.isdirectory(expanded_dir) ~= 1 then
          vim.notify(
            string.format("vibing.nvim: search_dir does not exist: %s", expanded_dir),
            vim.log.levels.WARN
          )
          goto continue
        end

        add_directory_if_exists(expanded_dir, directories)
        ::continue::
      end
    else
      -- デフォルト動作: 複数の標準ディレクトリを検索
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

  for _, directory in ipairs(M.get_search_directories(include_all, config)) do
    for _, file_path in ipairs(M.find_vibing_files(directory)) do
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
