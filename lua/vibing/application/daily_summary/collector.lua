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
---@param target_date string
---@return {user: string, assistant: string, timestamp: string, file: string}[]
function M.collect_messages_from_file(file_path, target_date)
  local messages = {}
  local file = io.open(file_path, "r")
  if not file then
    return messages
  end

  local content = file:read("*all")
  file:close()

  if not content or content == "" then
    return messages
  end

  local lines = vim.split(content, "\n")
  local sections = extract_all_sections(lines)

  for i, section in ipairs(sections) do
    if section.role == "user" then
      local timestamp = Timestamp.extract_timestamp_from_comment(section.header)
      if timestamp and timestamp:sub(1, 10) == target_date then
        local assistant_content = ""
        if sections[i + 1] and sections[i + 1].role == "assistant" then
          assistant_content = table.concat(sections[i + 1].lines, "\n")
        end

        table.insert(messages, {
          user = table.concat(section.lines, "\n"),
          assistant = assistant_content,
          timestamp = timestamp,
          file = vim.fn.fnamemodify(file_path, ":."),
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
    add_directory_if_exists(project_root .. "/.vibing/chat/", directories)
    add_directory_if_exists(vim.fn.stdpath("data") .. "/vibing/chats/", directories)
    if config.chat and config.chat.save_dir then
      add_directory_if_exists(config.chat.save_dir, directories)
    end
  else
    local FileManager = require("vibing.presentation.chat.modules.file_manager")
    local save_dir = FileManager.get_save_directory(config.chat or {})
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
        table.insert(source_files, vim.fn.fnamemodify(file_path, ":."))
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
