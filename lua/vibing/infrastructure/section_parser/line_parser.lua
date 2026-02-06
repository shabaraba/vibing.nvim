---@class Vibing.Infrastructure.LineParser : Vibing.Infrastructure.SectionParser
---Fallback section parsing using line-by-line reading
---Used in environments where grep command is unavailable (Windows, etc.)

local Base = require("vibing.infrastructure.section_parser.base")
local Timestamp = require("vibing.core.utils.timestamp")

local LineParser = setmetatable({}, { __index = Base })
LineParser.__index = LineParser

---Create a LineParser instance
---@return Vibing.Infrastructure.LineParser
function LineParser:new()
  local instance = setmetatable({}, self)
  instance.name = "line_parser"
  return instance
end

---Always available (pure Lua implementation)
---@return boolean
function LineParser:supports_platform()
  return true
end

---@param file_path string
---@return string
local function to_tilde_path(file_path)
  return vim.fn.fnamemodify(file_path, ":p:~")
end

---Extract messages for a specific date from a file
---@param file_path string Path to chat file
---@param target_date string Target date (YYYY-MM-DD)
---@return Vibing.Infrastructure.SectionParser.Message[] messages
---@return string? error Error message (only on failure)
function LineParser:extract_messages(file_path, target_date)
  if vim.fn.filereadable(file_path) ~= 1 then
    return {}, "File does not exist: " .. file_path
  end

  local lines = vim.fn.readfile(file_path)
  if #lines == 0 then
    return {}, nil
  end

  local messages = {}
  local normalized_path = to_tilde_path(file_path)

  -- State machine for parsing
  local current_message = nil
  local current_role = nil
  local current_lines = {}

  for _, line in ipairs(lines) do
    local role = Timestamp.extract_role(line)

    if role == "user" then
      -- Save previous message if exists and matches target date
      if current_message and current_message.timestamp then
        if current_message.timestamp:sub(1, 10) == target_date then
          current_message.user = table.concat(current_message.user_lines, "\n")
          current_message.assistant = table.concat(current_message.assistant_lines, "\n")
          current_message.user_lines = nil
          current_message.assistant_lines = nil
          table.insert(messages, current_message)
        end
      end

      -- Start new message
      local timestamp = Timestamp.extract_timestamp_from_comment(line)
      current_message = {
        timestamp = timestamp,
        file = normalized_path,
        user_lines = {},
        assistant_lines = {},
      }
      current_role = "user"
      current_lines = current_message.user_lines

    elseif role == "assistant" then
      if current_message then
        current_role = "assistant"
        current_lines = current_message.assistant_lines
      end

    elseif current_message and current_role then
      -- Skip metadata lines
      if not line:match("^---") and not line:match("^Context:") then
        table.insert(current_lines, line)
      end
    end
  end

  -- Handle last message
  if current_message and current_message.timestamp then
    if current_message.timestamp:sub(1, 10) == target_date then
      current_message.user = table.concat(current_message.user_lines, "\n")
      current_message.assistant = table.concat(current_message.assistant_lines, "\n")
      current_message.user_lines = nil
      current_message.assistant_lines = nil
      table.insert(messages, current_message)
    end
  end

  return messages, nil
end

return LineParser
