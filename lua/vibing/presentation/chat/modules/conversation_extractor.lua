local Timestamp = require("vibing.core.utils.timestamp")

local M = {}

---セクションの内容を会話配列に追加
---@param conversation table 会話配列
---@param role string|nil 現在のロール
---@param content table 内容行の配列
local function save_section(conversation, role, content)
  if role and #content > 0 then
    local content_str = vim.trim(table.concat(content, "\n"))
    if content_str ~= "" then
      table.insert(conversation, {
        role = role,
        content = content_str,
      })
    end
  end
end

---会話履歴全体を抽出
---@param buf number バッファ番号
---@return {role: string, content: string}[]
function M.extract_conversation(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local conversation = {}
  local current_role = nil
  local current_content = {}

  for _, line in ipairs(lines) do
    local role = Timestamp.extract_role(line)

    if role == "user" or role == "assistant" then
      save_section(conversation, current_role, current_content)
      current_role = role
      current_content = {}
    elseif
      current_role
      and not Timestamp.is_header(line)
      and not line:match("^---")
      and not line:match("^Context:")
    then
      table.insert(current_content, line)
    end
  end

  save_section(conversation, current_role, current_content)

  return conversation
end

---ユーザーメッセージを抽出（最後の## Userセクション）
---@param buf number バッファ番号
---@return string?
function M.extract_user_message(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local last_user_line = nil
  for i = #lines, 1, -1 do
    local role = Timestamp.extract_role(lines[i])
    if role == "user" then
      last_user_line = i
      break
    end
  end

  if not last_user_line then
    return nil
  end

  local message_lines = {}
  for i = last_user_line + 1, #lines do
    local line = lines[i]
    if Timestamp.is_header(line) then
      break
    end
    table.insert(message_lines, line)
  end

  while #message_lines > 0 and message_lines[1] == "" do
    table.remove(message_lines, 1)
  end
  while #message_lines > 0 and message_lines[#message_lines] == "" do
    table.remove(message_lines)
  end

  if #message_lines == 0 then
    return nil
  end

  return table.concat(message_lines, "\n")
end

---未送信ヘッダーをタイムスタンプ付きヘッダーに置き換える
---@param buf number バッファ番号
function M.commit_user_message(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local last_unsent_user_line = nil

  for i = #lines, 1, -1 do
    if Timestamp.is_unsent_user_header(lines[i]) then
      last_unsent_user_line = i
      break
    end
  end

  if not last_unsent_user_line then
    return
  end

  local timestamped_header = Timestamp.create_user_header_with_timestamp()
  vim.api.nvim_buf_set_lines(
    buf,
    last_unsent_user_line - 1,
    last_unsent_user_line,
    false,
    { timestamped_header }
  )
end

return M
