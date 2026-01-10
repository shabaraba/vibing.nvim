---@class Vibing.Presentation.PatchFinder
local M = {}

local MODIFIED_FILES_PATTERN = "^###? Modified Files"
local PATCH_COMMENT_PATTERN = "<!%-%- patch: ([^%s]+) %-%-?>"
local NEXT_ASSISTANT_PATTERN = "^## %d%d%d%d%-%d%d%-%d%d .* Assistant"
local HEADER_PATTERN = "^##[^#]"

---@param buf number
---@return string[]
local function get_buffer_lines(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param lines string[]
---@param from_line number
---@return number?
local function find_modified_files_section(lines, from_line)
  for i = from_line, 1, -1 do
    local line = lines[i]
    if line:match(MODIFIED_FILES_PATTERN) then
      return i
    end
    if line:match(HEADER_PATTERN) and not line:match("Modified Files") then
      return nil
    end
  end
  return nil
end

---@param buf number
---@return string?
function M.find_nearest_patch(buf)
  local lines = get_buffer_lines(buf)
  if #lines == 0 then return nil end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local section_start = find_modified_files_section(lines, cursor_line)
  if not section_start then return nil end

  for i = section_start, #lines do
    local line = lines[i]
    local patch_filename = line:match(PATCH_COMMENT_PATTERN)
    if patch_filename then
      return patch_filename
    end
    if line:match(NEXT_ASSISTANT_PATTERN) then
      break
    end
  end

  return nil
end

---@param buf number
---@return string?
function M.get_session_id(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, 50, false)
  local in_frontmatter = false

  for _, line in ipairs(lines) do
    if line == "---" then
      if in_frontmatter then break end
      in_frontmatter = true
    elseif in_frontmatter then
      local session_id = line:match("^session_id:%s*(.+)$")
      if session_id then
        return vim.trim(session_id)
      end
    end
  end

  return nil
end

---@param buf number
---@return string[]
function M.get_modified_files_in_section(buf)
  local lines = get_buffer_lines(buf)
  if #lines == 0 then return {} end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local section_start = find_modified_files_section(lines, cursor_line)
  if not section_start then return {} end

  local files = {}
  for i = section_start + 1, #lines do
    local line = lines[i]
    if line:match(HEADER_PATTERN) or line:match("^# ") then
      break
    end
    if not line:match("<!%-%-") then
      local trimmed = vim.trim(line)
      if trimmed ~= "" and not trimmed:match("^%-%-") then
        table.insert(files, trimmed)
      end
    end
  end

  return files
end

return M
