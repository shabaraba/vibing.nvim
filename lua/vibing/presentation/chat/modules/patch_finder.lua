---@class Vibing.Presentation.PatchFinder
local M = {}

local MODIFIED_FILES_PATTERN = "^###? Modified Files"
---patch行は素の `Patch: <path>` で書かれる。`<!-- patch: ... -->` は隠していた頃の形で、
---保存済みのチャットから今も開かれるので読めるままにしておく
---パスは空白を含みうる（ワークスペース名やworktree名に空白が入る）。`[^%s]+` で切ると
---`gd` がそのターンのpatchを見つけられず、黙ってHEAD差分に落ちる。
---空白を許すかわりに末尾の `.patch` を必須にする — これが無いと "Patch: applied two files"
---のような地の文まで拾ってしまう。書き手（`send_message.lua`）は常に `.patch` を付ける
local PATCH_PATTERNS = {
  "^Patch:%s+(.-%.patch)%s*$",
  "<!%-%- patch: (.-%.patch) %-%-?>",
}

---@param line string
---@return string?
function M.parse_patch_line(line)
  for _, pattern in ipairs(PATCH_PATTERNS) do
    local path = line:match(pattern)
    if path then
      return path
    end
  end
  return nil
end
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
    local patch_filename = M.parse_patch_line(line)
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

return M
