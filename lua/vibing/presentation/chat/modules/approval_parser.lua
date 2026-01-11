---@class Vibing.ApprovalParser
---承認レスポンスをパースするモジュール
local M = {}

---承認レスポンスかどうかを判定
---@param message string ユーザーメッセージ
---@return boolean
function M.is_approval_response(message)
  -- 承認選択肢のパターンをチェック
  local patterns = {
    "allow_once",
    "deny_once",
    "allow_for_session",
    "deny_for_session",
  }

  for _, pattern in ipairs(patterns) do
    if message:match(pattern) then
      return true
    end
  end

  return false
end

---承認レスポンスをパース
---@param message string ユーザーメッセージ
---@return {action: string, tool: string?}?
function M.parse_approval_response(message)
  -- Extract the selected option from numbered list format
  -- Example: "1. allow_once - Allow this execution only"

  local action = nil

  -- Check for each approval action
  if message:match("allow_once") then
    action = "allow_once"
  elseif message:match("deny_once") then
    action = "deny_once"
  elseif message:match("allow_for_session") then
    action = "allow_for_session"
  elseif message:match("deny_for_session") then
    action = "deny_for_session"
  end

  if not action then
    return nil
  end

  -- Extract tool name from the message (optional)
  -- Pattern: "Tool: <tool_name>"
  local tool = message:match("Tool:%s*(%S+)")

  return {
    action = action,
    tool = tool,
  }
end

---承認アクションに基づいてメッセージを生成
---@param action string 承認アクション
---@param tool string? ツール名
---@return string
function M.generate_response_message(action, tool)
  local tool_display = tool or "the tool"

  if action == "allow_once" then
    return string.format("User approved %s for this execution. Please try again.", tool_display)
  elseif action == "deny_once" then
    return string.format("User denied %s for this execution. Please use an alternative approach.", tool_display)
  elseif action == "allow_for_session" then
    return string.format("User approved %s for this session. Please try again.", tool_display)
  elseif action == "deny_for_session" then
    return string.format("User denied %s for this session. Please use an alternative approach.", tool_display)
  end

  return "Unknown approval action."
end

return M
