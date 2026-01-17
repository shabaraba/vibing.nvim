---@class Vibing.Presentation.Chat.HeaderRenderer
---メッセージヘッダーのレンダリング責務
---Squad名を含むヘッダー文字列の生成とパース
local M = {}

local Timestamp = require("vibing.core.utils.timestamp")

---Assistantヘッダーを生成（Squad名付き、タイムスタンプなし）
---@param squad_name? string Squad名（省略時はレガシー形式 "## Assistant"）
---@return string header Assistantヘッダー
function M.render_assistant_header(squad_name)
  if not squad_name or squad_name == "" then
    return "## Assistant"
  end

  return string.format("## Assistant <%s>", squad_name)
end

---Assistantヘッダー（他バッファへ送信用、タイムスタンプ付き）を生成
---Phase 3（メンション機能）で使用予定
---@param squad_name string Squad名
---@param timestamp? string タイムスタンプ（省略時は現在時刻）
---@return string header Assistantヘッダー
function M.render_assistant_header_with_timestamp(squad_name, timestamp)
  timestamp = timestamp or Timestamp.now()
  return string.format("## Assistant <%s> <!-- %s -->", squad_name, timestamp)
end

---ヘッダー行からロール、Squad名、タイムスタンプを抽出
---@param line string ヘッダー行
---@return table? parsed { role: string, squad_name?: string, timestamp?: string }（ヘッダーでない場合nil）
function M.parse_header(line)
  -- Assistant with Squad name and timestamp: "## Assistant <Alpha> <!-- 2025-01-15 10:35:00 -->"
  local squad_name, timestamp = line:match(
    "^## Assistant <(%w+)> <!%-%- (%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d) %-%->"
  )
  if squad_name and timestamp then
    return {
      role = "assistant",
      squad_name = squad_name,
      timestamp = timestamp,
    }
  end

  -- Assistant with Squad name (no timestamp): "## Assistant <Alpha>"
  squad_name = line:match("^## Assistant <(%w+)>$")
  if squad_name then
    return {
      role = "assistant",
      squad_name = squad_name,
    }
  end

  -- User or legacy Assistant: delegate to existing timestamp.lua
  local role = Timestamp.extract_role(line)
  if role then
    local ts = Timestamp.extract_timestamp_from_comment(line)
    return {
      role = role,
      timestamp = ts,
    }
  end

  return nil
end

---行がメッセージヘッダーかどうかチェック
---@param line string チェック対象の行
---@return boolean is_header ヘッダーの場合true
function M.is_header(line)
  return M.parse_header(line) ~= nil
end

return M
