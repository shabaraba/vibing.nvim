---@class Vibing.Presentation.PatchFinder
---Modified Filesセクションからpatchファイル名を見つける
local M = {}

---カーソル位置に最も近いpatchコメントを取得
---@param buf number バッファ番号
---@return string? patch_filename patchファイル名
function M.find_nearest_patch(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- カーソル位置から上方向にModified Filesセクションを探す
  local section_start = nil
  local section_end = nil

  for i = cursor_line, 1, -1 do
    local line = lines[i]
    if line:match("^###? Modified Files") then
      section_start = i
      break
    end
    -- 別のセクションに入ったら中断
    if line:match("^##[^#]") and not line:match("Modified Files") then
      break
    end
  end

  if not section_start then
    return nil
  end

  -- セクション終了位置を探す（次のヘッダーまたはファイル末尾）
  for i = section_start + 1, #lines do
    local line = lines[i]
    if line:match("^##[^#]") or line:match("^# ") then
      section_end = i - 1
      break
    end
  end

  section_end = section_end or #lines

  -- セクション内でpatchコメントを探す
  for i = section_start, section_end do
    local line = lines[i]
    local patch_filename = line:match("<!%-%- patch: ([^%s]+) %-%-?>")
    if patch_filename then
      return patch_filename
    end
  end

  return nil
end

---frontmatterからsession_idを取得
---@param buf number バッファ番号
---@return string? session_id
function M.get_session_id(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, 50, false) -- frontmatterは先頭50行以内

  local in_frontmatter = false
  for _, line in ipairs(lines) do
    if line == "---" then
      if in_frontmatter then
        break -- frontmatter終了
      else
        in_frontmatter = true
      end
    elseif in_frontmatter then
      local session_id = line:match("^session_id:%s*(.+)$")
      if session_id then
        return vim.trim(session_id)
      end
    end
  end

  return nil
end

---カーソル位置のModified Filesセクションに含まれるファイル一覧を取得
---@param buf number バッファ番号
---@return string[] files ファイルパスのリスト
function M.get_modified_files_in_section(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- カーソル位置から上方向にModified Filesセクションを探す
  local section_start = nil

  for i = cursor_line, 1, -1 do
    local line = lines[i]
    if line:match("^###? Modified Files") then
      section_start = i
      break
    end
    if line:match("^##[^#]") and not line:match("Modified Files") then
      break
    end
  end

  if not section_start then
    return {}
  end

  -- セクション内のファイルパスを収集
  local files = {}
  for i = section_start + 1, #lines do
    local line = lines[i]
    -- 次のヘッダーに到達したら終了
    if line:match("^##[^#]") or line:match("^# ") then
      break
    end
    -- コメント行やpatchコメントはスキップ
    if line:match("<!%-%-") then
      goto continue
    end
    -- 空行以外のファイルパスを追加
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not trimmed:match("^%-%-") then
      table.insert(files, trimmed)
    end
    ::continue::
  end

  return files
end

return M
