local M = {}

---Find "# Vibing Chat" line and first "---" separator after it
---@param buf number
---@return number? vibing_chat_line 1-indexed line number
---@return number? separator_line 1-indexed line number
local function find_insertion_points(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local vibing_chat_line = nil
  local separator_line = nil

  local in_frontmatter = false

  for i, line in ipairs(lines) do
    if i == 1 and line == "---" then
      in_frontmatter = true
    elseif in_frontmatter and line == "---" then
      in_frontmatter = false
    elseif not in_frontmatter then
      if line:match("^# Vibing Chat") then
        vibing_chat_line = i
      elseif vibing_chat_line and line:match("^%-%-%-$") then
        separator_line = i
        break
      end
    end
  end

  return vibing_chat_line, separator_line
end

---Find existing ## summary section between start and end lines
---@param buf number
---@param start_line number 1-indexed search start
---@param end_line number 1-indexed search end
---@return number? summary_start 1-indexed start line
---@return number? summary_end 1-indexed end line (inclusive)
local function find_summary_section(buf, start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local summary_start = nil
  local summary_end = nil

  for i, line in ipairs(lines) do
    local actual_line = start_line + i - 1
    if line:lower():match("^##%s*summary") then
      summary_start = actual_line
    elseif summary_start and (line:match("^##%s[^#]") or line:match("^%-%-%-$")) then
      summary_end = actual_line - 1
      break
    end
  end

  if summary_start and not summary_end then
    summary_end = end_line - 1
  end

  return summary_start, summary_end
end

---Insert or update summary section in buffer
---@param buf number Buffer number
---@param summary_content string AI-generated summary (should start with "## summary")
---@return boolean success
function M.insert_or_update(buf, summary_content)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    vim.notify("[vibing] Invalid buffer", vim.log.levels.ERROR)
    return false
  end

  local vibing_chat_line, separator_line = find_insertion_points(buf)

  if not vibing_chat_line or not separator_line then
    vim.notify("[vibing] Cannot find insertion points (# Vibing Chat or ---)", vim.log.levels.ERROR)
    return false
  end

  local summary_start, summary_end = find_summary_section(buf, vibing_chat_line, separator_line)

  local summary_lines = vim.split(summary_content, "\n", { plain = true })

  while #summary_lines > 0 and vim.trim(summary_lines[1]) == "" do
    table.remove(summary_lines, 1)
  end
  while #summary_lines > 0 and vim.trim(summary_lines[#summary_lines]) == "" do
    table.remove(summary_lines)
  end

  table.insert(summary_lines, "")

  if summary_start and summary_end then
    vim.api.nvim_buf_set_lines(buf, summary_start - 1, summary_end, false, summary_lines)
  else
    local insert_pos = vibing_chat_line
    table.insert(summary_lines, 1, "")
    vim.api.nvim_buf_set_lines(buf, insert_pos, insert_pos, false, summary_lines)
  end

  return true
end

return M
