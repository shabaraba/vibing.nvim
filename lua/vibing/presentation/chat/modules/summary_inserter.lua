local M = {}

local notify = require("vibing.core.utils.notify")

---Find "# Vibing Chat" line and first "---" separator after it
---@param lines string[]
---@return number? vibing_chat_line 1-indexed line number
---@return number? separator_line 1-indexed line number
local function find_insertion_points(lines)
  local vibing_chat_line = nil
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
        return vibing_chat_line, i
      end
    end
  end

  return vibing_chat_line, nil
end

---Find existing ## summary section between start and end lines
---
---The `^## ` / `^---$` terminators below, together with the first-line check in
---`prepare_summary_lines`, are a format contract with `prompts/chat_summary.md`: the model is told
---to emit `## summary` first and nothing but `###`-or-deeper headings after it, because a
---`##` in the body ends the section here and leaves the tail of the previous summary orphaned on the
---next `:VibingSummarize`. Loosen the template only together with these two patterns.
---@param lines string[]
---@param start_line number 1-indexed search start
---@param end_line number 1-indexed search end
---@return number? summary_start 1-indexed start line
---@return number? summary_end 1-indexed end line (inclusive)
local function find_summary_section(lines, start_line, end_line)
  local summary_start = nil

  for i = start_line, end_line do
    local line = lines[i]
    if line:lower():match("^##%s*summary") then
      summary_start = i
    elseif summary_start and (line:match("^##%s") or line:match("^%-%-%-$")) then
      return summary_start, i - 1
    end
  end

  if summary_start then
    return summary_start, end_line - 1
  end

  return nil, nil
end

---Trim leading and trailing empty lines from summary
---@param summary_content string
---@return string[]? lines Nil if invalid format
local function prepare_summary_lines(summary_content)
  local lines = vim.split(summary_content, "\n", { plain = true })

  while #lines > 0 and vim.trim(lines[1]) == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end

  -- Validate that first line starts with "## summary"
  if #lines == 0 or not lines[1]:lower():match("^##%s*summary") then
    return nil
  end

  table.insert(lines, "")
  return lines
end

---Insert or update summary section in buffer
---@param buf number Buffer number
---@param summary_content string AI-generated summary (should start with "## summary")
---@return boolean success
function M.insert_or_update(buf, summary_content)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    notify.error("Invalid buffer")
    return false
  end

  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local vibing_chat_line, separator_line = find_insertion_points(all_lines)

  if not vibing_chat_line or not separator_line then
    notify.error("Cannot find insertion points (# Vibing Chat or ---)")
    return false
  end

  local summary_start, summary_end = find_summary_section(all_lines, vibing_chat_line, separator_line)
  local summary_lines = prepare_summary_lines(summary_content)

  if not summary_lines then
    notify.error("Invalid summary format: must start with '## summary'")
    return false
  end

  if summary_start and summary_end then
    vim.api.nvim_buf_set_lines(buf, summary_start - 1, summary_end, false, summary_lines)
  else
    table.insert(summary_lines, 1, "")
    vim.api.nvim_buf_set_lines(buf, vibing_chat_line, vibing_chat_line, false, summary_lines)
  end

  return true
end

---バッファから `## summary` セクションを取り出す。
---
---探索範囲も終端の判定も `M.insert_or_update` と同じもの（`find_insertion_points` /
---`find_summary_section`）を使う。読む側と書く側でセクション境界の定義がずれると、
---次の `:VibingSummarize` が上書きするのと違う範囲をタイトル生成が読むことになるため、
---別モジュールに切り出さずここに置いている。
---
---見出しだけで本文が空のセクションは nil を返す。タイトル生成側はこれを
---「summary は無い」と読んで抜粋にフォールバックする。
---@param buf number バッファ番号
---@return string? summary `## summary` 見出しを含む本文。無ければ nil
function M.extract(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local vibing_chat_line, separator_line = find_insertion_points(all_lines)

  if not vibing_chat_line or not separator_line then
    return nil
  end

  local summary_start, summary_end = find_summary_section(all_lines, vibing_chat_line, separator_line)

  if not summary_start or not summary_end then
    return nil
  end

  local body = vim.trim(table.concat(vim.list_slice(all_lines, summary_start + 1, summary_end), "\n"))
  if body == "" then
    return nil
  end

  return vim.trim(all_lines[summary_start]) .. "\n\n" .. body
end

return M
