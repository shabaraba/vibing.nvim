local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

local M = {}

-- Every function here reads `Frontmatter.buffer_region`, which follows the
-- frontmatter to its closing `---`, rather than a fixed number of lines. A window
-- is the wrong shape for this: a chat's frontmatter grows with its permission and
-- orchestration lists, and each of these functions fails *silently* past the
-- window — `parse` returns an empty table, `update_field`/`update_list` report
-- false, and `update_session_id` simply writes nothing, losing the session id.

---フロントマターをパース
---@param buf number バッファ番号
---@return table<string, string|string[]|number|boolean>
function M.parse(buf)
  local region = Frontmatter.buffer_region(buf)
  if not region then
    return {}
  end

  return Frontmatter.parse(table.concat(region, "\n")) or {}
end

---session_idを更新
---@param buf number バッファ番号
---@param session_id string セッションID
function M.update_session_id(buf, session_id)
  local region = Frontmatter.buffer_region(buf)
  if not region then
    return
  end

  for i, line in ipairs(region) do
    if line:match("^session_id:") then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { "session_id: " .. session_id })
      return
    end
  end
end

---フロントマターのフィールドを更新または追加
---@param buf number バッファ番号
---@param key string キー
---@param value string 値
---@param update_timestamp? boolean タイムスタンプを更新するか
---@return boolean success
function M.update_field(buf, key, value, update_timestamp)
  if not key or key == "" then
    return false
  end

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  if update_timestamp == nil then
    update_timestamp = true
  end

  local function escape_pattern(str)
    return str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
  end

  -- 正式なキーに加えて、その旧綴り(Frontmatter.LEGACY_KEY_ALIASES)の行も書き換え対象にする。
  -- そうしないと旧キーの行が残ったまま正式なキーの行が追加され、1つのfrontmatterに
  -- 同じ設定が二重に並ぶ。
  -- 正式なキーを先頭に置く。複数の旧綴りが同じcanonicalを指すようになった場合、どの行を
  -- 「残す1行」にするかは下のmatched_lines[1]（＝出現順で最初の行）で決まる。
  local key_patterns = { "^" .. escape_pattern(key) .. ":" }
  for legacy, canonical in pairs(Frontmatter.LEGACY_KEY_ALIASES) do
    if canonical == key then
      table.insert(key_patterns, "^" .. escape_pattern(legacy) .. ":")
    end
  end

  local region = Frontmatter.buffer_region(buf)
  if not region then
    return false
  end

  -- 領域の末尾要素が閉じ`---`
  local frontmatter_end = #region
  -- 正式キーと旧綴りの行を全部拾う。旧バージョンが両方の行を書いてしまったファイルが実在しうる
  -- ので、1本だけ残して残りは消さないと重複が永久に残る。
  local matched_lines = {}

  for i = 2, frontmatter_end - 1 do
    for _, pattern in ipairs(key_patterns) do
      if region[i]:match(pattern) then
        table.insert(matched_lines, i)
        break
      end
    end
  end

  -- 後ろから消して、先頭の1本（なければ挿入位置）だけを書き換え対象に残す
  for i = #matched_lines, 2, -1 do
    local line_nr = matched_lines[i]
    vim.api.nvim_buf_set_lines(buf, line_nr - 1, line_nr, false, {})
    frontmatter_end = frontmatter_end - 1
  end
  local key_line = matched_lines[1]

  -- valueがnilの場合はフィールドを削除
  if value == nil then
    if key_line then
      vim.api.nvim_buf_set_lines(buf, key_line - 1, key_line, false, {})
    end
    return true
  end

  local new_line = key .. ": " .. value

  if key_line then
    vim.api.nvim_buf_set_lines(buf, key_line - 1, key_line, false, { new_line })
  else
    vim.api.nvim_buf_set_lines(buf, frontmatter_end - 1, frontmatter_end - 1, false, { new_line })
  end

  if update_timestamp and key ~= "updated_at" then
    M.update_field(buf, "updated_at", os.date("%Y-%m-%dT%H:%M:%S"), false)
  end

  return true
end

---フロントマターのリストフィールドを更新（追加/削除）
---@param buf number バッファ番号
---@param key string フィールド名
---@param value string 追加/削除する値
---@param action "add"|"remove" 操作種別
---@return boolean success
function M.update_list(buf, key, value, action)
  if not key or key == "" or not value or value == "" then
    return false
  end

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  local region = Frontmatter.buffer_region(buf)
  if not region then
    return false
  end

  -- 領域の末尾要素が閉じ`---`
  local frontmatter_end = #region
  local key_start = nil
  local key_end = nil
  local current_items = {}

  local in_target_list = false

  for i = 2, frontmatter_end - 1 do
    local line = region[i]
    if line:sub(1, #key + 1) == key .. ":" then
      key_start = i
      in_target_list = true
    elseif in_target_list then
      local item = line:match("^  %- (.+)$")
      if item then
        table.insert(current_items, item)
      else
        key_end = i - 1
        in_target_list = false
      end
    end
  end

  -- リストが閉じ`---`まで続いていた場合、その直前が終端
  if in_target_list then
    key_end = frontmatter_end - 1
  end

  -- リストを更新
  if action == "add" then
    local exists = false
    for _, item in ipairs(current_items) do
      if item == value then
        exists = true
        break
      end
    end
    if not exists then
      table.insert(current_items, value)
    end
  elseif action == "remove" then
    local new_items = {}
    for _, item in ipairs(current_items) do
      if item ~= value then
        table.insert(new_items, item)
      end
    end
    current_items = new_items
  end

  -- 新しいリスト行を生成
  local new_lines = {}
  if #current_items > 0 then
    table.insert(new_lines, key .. ":")
    for _, item in ipairs(current_items) do
      table.insert(new_lines, "  - " .. item)
    end
  end

  -- バッファを更新
  if key_start then
    local end_line = key_end or key_start
    vim.api.nvim_buf_set_lines(buf, key_start - 1, end_line, false, new_lines)
  elseif #current_items > 0 then
    vim.api.nvim_buf_set_lines(buf, frontmatter_end - 1, frontmatter_end - 1, false, new_lines)
  end

  M.update_field(buf, "updated_at", os.date("%Y-%m-%dT%H:%M:%S"), false)
  return true
end

---フロントマターのリストフィールドを取得
---@param buf number バッファ番号
---@param key string フィールド名
---@return string[] items
function M.get_list(buf, key)
  local frontmatter = M.parse(buf)
  return Frontmatter.as_list(frontmatter[key])
end

return M
