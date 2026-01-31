local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

local M = {}

---フロントマターをパース
---@param buf number バッファ番号
---@return table<string, string|string[]|number|boolean>
function M.parse(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, 50, false)
  local content = table.concat(lines, "\n")
  local parsed = Frontmatter.parse(content)

  return parsed or {}
end

---session_idを更新
---@param buf number バッファ番号
---@param session_id string セッションID
function M.update_session_id(buf, session_id)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, 10, false)
  for i, line in ipairs(lines) do
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

  local lines = vim.api.nvim_buf_get_lines(buf, 0, 20, false)
  local frontmatter_end = 0
  local key_line = nil
  local escaped_key = escape_pattern(key)

  for i, line in ipairs(lines) do
    if i == 1 and line == "---" then
      -- frontmatter開始
    elseif line == "---" then
      frontmatter_end = i
      break
    elseif line:match("^" .. escaped_key .. ":") then
      key_line = i
    end
  end

  if frontmatter_end == 0 then
    return false
  end

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

  local lines = vim.api.nvim_buf_get_lines(buf, 0, 50, false)

  local frontmatter_end = 0
  local key_start = nil
  local key_end = nil
  local current_items = {}

  local in_frontmatter = false
  local in_target_list = false

  for i, line in ipairs(lines) do
    if i == 1 and line == "---" then
      in_frontmatter = true
    elseif in_frontmatter and line == "---" then
      frontmatter_end = i
      if in_target_list then
        key_end = i - 1
      end
      break
    elseif in_frontmatter then
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
  end

  if frontmatter_end == 0 then
    return false
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
  return frontmatter[key] or {}
end

return M
