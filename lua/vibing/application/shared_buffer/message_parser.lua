---Message parser for shared buffer
---Parses messages and extracts mentions for multi-agent coordination
local M = {}

---@class SharedMessage
---@field timestamp string
---@field from_claude_id string
---@field mentions string[] メンションされた Claude ID のリスト (@Claude-1, @All など)
---@field content string
---@field line_number number

---行をパースしてメッセージ構造を抽出
---@param lines string[]
---@param start_line? number 開始行番号（デフォルト: 1）
---@return SharedMessage[]
function M.parse_lines(lines, start_line)
  start_line = start_line or 1
  local messages = {}

  for i, line in ipairs(lines) do
    -- ヘッダーフォーマット: ## 2026-01-11 18:00:00 Claude-1
    local timestamp, claude_id = line:match("^## (%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d) Claude%-(%w+)")

    if timestamp and claude_id then
      -- メンションを抽出: @Claude-1, @Claude-2, @All
      local mentions = {}
      for mention in line:gmatch("@(Claude%-%w+)") do
        table.insert(mentions, mention)
      end
      for mention in line:gmatch("@(All)") do
        table.insert(mentions, mention)
      end

      table.insert(messages, {
        timestamp = timestamp,
        from_claude_id = claude_id,
        mentions = mentions,
        content = line,
        line_number = start_line + i - 1,
      })
    end
  end

  return messages
end

---バッファ全体をパースしてメッセージを抽出
---@param bufnr number
---@return SharedMessage[]
function M.parse_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return M.parse_lines(lines, 1)
end

---メンションが特定の Claude ID を含むか確認
---@param message SharedMessage
---@param claude_id string
---@return boolean
function M.has_mention(message, claude_id)
  -- @All が含まれていれば全員が対象
  if vim.tbl_contains(message.mentions, "All") then
    return true
  end

  -- 特定の Claude ID が含まれているか確認
  return vim.tbl_contains(message.mentions, claude_id)
end

---メッセージが特定の Claude から送信されたか確認
---@param message SharedMessage
---@param claude_id string
---@return boolean
function M.is_from(message, claude_id)
  return message.from_claude_id == claude_id
end

---Claude ID からフォーマットされたヘッダーを生成
---@param claude_id string
---@param content? string オプションのコンテンツ
---@return string
function M.create_header(claude_id, content)
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local header = string.format("## %s Claude-%s", timestamp, claude_id)

  if content and content ~= "" then
    header = header .. "\n\n" .. content
  end

  return header
end

return M
