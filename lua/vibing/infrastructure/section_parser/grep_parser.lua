---@class Vibing.Infrastructure.GrepParser : Vibing.Infrastructure.SectionParser
---Fast section parsing using grep command
---Available on macOS/Linux environments

local Base = require("vibing.infrastructure.section_parser.base")

local GrepParser = setmetatable({}, { __index = Base })
GrepParser.__index = GrepParser

---Create a GrepParser instance
---@return Vibing.Infrastructure.GrepParser
function GrepParser:new()
  local instance = setmetatable({}, self)
  instance.name = "grep_parser"
  return instance
end

---Check if grep command is available
---@return boolean
function GrepParser:supports_platform()
  local result = vim.system({ "which", "grep" }, { text = true }):wait()
  return result.code == 0
end

---@class HeaderInfo
---@field line_number number Line number in file (1-based)
---@field role "user" | "assistant" Role extracted from header
---@field timestamp string? Timestamp if present (for user headers)

---Parse grep output line into HeaderInfo
---@param grep_line string Single line from grep -n output (e.g., "15:## User <!-- 2025-01-26 10:30:00 -->")
---@return HeaderInfo? header_info Parsed info or nil if invalid
local function parse_grep_line(grep_line)
  local line_num_str, content = grep_line:match("^(%d+):(.+)$")
  if not line_num_str then
    return nil
  end

  local line_number = tonumber(line_num_str)
  local role = nil
  local timestamp = nil

  -- Check for User header with timestamp
  local ts = content:match("^## User <!%-%- (%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d) %-%->$")
  if ts then
    role = "user"
    timestamp = ts
  elseif content:match("^## User") then
    role = "user"
  elseif content:match("^## Assistant") then
    role = "assistant"
  end

  if not role then
    return nil
  end

  return {
    line_number = line_number,
    role = role,
    timestamp = timestamp,
  }
end

---Find message ranges for target date from header list
---Returns array of {start_line, end_line, timestamp} for each matching message
---
---@param headers HeaderInfo[] Sorted list of all headers
---@param target_date string Target date (YYYY-MM-DD)
---@param total_lines number Total lines in file (for last message boundary)
---@return {start_line: number, end_line: number, timestamp: string}[] ranges
local function find_message_ranges(headers, target_date, total_lines)
  local ranges = {}

  -- Collect User header indices for boundary calculation
  local user_indices = {}
  for i, h in ipairs(headers) do
    if h.role == "user" then
      table.insert(user_indices, i)
    end
  end

  -- Find matching User headers and calculate ranges
  for idx, header_idx in ipairs(user_indices) do
    local header = headers[header_idx]
    if header.timestamp and header.timestamp:sub(1, 10) == target_date then
      local next_user_idx = user_indices[idx + 1]
      local end_line = next_user_idx and (headers[next_user_idx].line_number - 1) or total_lines

      table.insert(ranges, {
        start_line = header.line_number,
        end_line = end_line,
        timestamp = header.timestamp,
      })
    end
  end

  return ranges
end

---Read specific line range from file
---@param file_path string
---@param start_line number
---@param end_line number
---@return string[] lines
local function read_line_range(file_path, start_line, end_line)
  -- Use sed for efficient range reading
  local cmd = {
    "sed", "-n",
    string.format("%d,%dp", start_line, end_line),
    file_path,
  }

  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 or not result.stdout then
    return {}
  end

  local lines = {}
  for line in result.stdout:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end
  return lines
end

---Parse lines into user and assistant content
---@param lines string[]
---@return string user_content
---@return string assistant_content
local function parse_message_content(lines)
  local user_lines = {}
  local assistant_lines = {}
  local current_role = nil

  for _, line in ipairs(lines) do
    if line:match("^## User") then
      current_role = "user"
    elseif line:match("^## Assistant") then
      current_role = "assistant"
    elseif current_role and not line:match("^---") and not line:match("^Context:") then
      if current_role == "user" then
        table.insert(user_lines, line)
      else
        table.insert(assistant_lines, line)
      end
    end
  end

  return table.concat(user_lines, "\n"), table.concat(assistant_lines, "\n")
end

---@param file_path string
---@return string
local function to_tilde_path(file_path)
  return vim.fn.fnamemodify(file_path, ":p:~")
end

---Extract messages for a specific date from a file
---@param file_path string Path to .vibing file
---@param target_date string Target date (YYYY-MM-DD)
---@return Vibing.Infrastructure.SectionParser.Message[] messages
---@return string? error Error message (only on failure)
function GrepParser:extract_messages(file_path, target_date)
  if vim.fn.filereadable(file_path) ~= 1 then
    return {}, "File does not exist: " .. file_path
  end

  -- Step 1: Get all headers with line numbers using grep
  local grep_cmd = {
    "grep", "-n",
    "-E", "^## (User|Assistant)",
    file_path,
  }

  local grep_result = vim.system(grep_cmd, { text = true }):wait()

  -- grep returns 1 if no matches (acceptable)
  if grep_result.code ~= 0 and grep_result.code ~= 1 then
    return {}, "grep failed: " .. (grep_result.stderr or "unknown error")
  end

  if not grep_result.stdout or grep_result.stdout == "" then
    return {}, nil  -- No headers found, not an error
  end

  -- Step 2: Parse grep output into headers
  local headers = {}
  for line in grep_result.stdout:gmatch("[^\r\n]+") do
    local header = parse_grep_line(line)
    if header then
      table.insert(headers, header)
    end
  end

  if #headers == 0 then
    return {}, nil
  end

  -- Step 3: Get total line count
  local wc_result = vim.system({ "wc", "-l", file_path }, { text = true }):wait()
  local total_lines = tonumber(wc_result.stdout:match("(%d+)")) or 0

  -- Step 4: Find ranges for target date
  local ranges = find_message_ranges(headers, target_date, total_lines)

  if #ranges == 0 then
    return {}, nil
  end

  -- Step 5: Read and parse each range
  local messages = {}
  local normalized_path = to_tilde_path(file_path)

  for _, range in ipairs(ranges) do
    local lines = read_line_range(file_path, range.start_line, range.end_line)
    local user_content, assistant_content = parse_message_content(lines)

    table.insert(messages, {
      user = user_content,
      assistant = assistant_content,
      timestamp = range.timestamp,
      file = normalized_path,
    })
  end

  return messages, nil
end

return GrepParser
