---@class Vibing.ApprovalParser
---承認レスポンスをパースするモジュール
local M = {}

---承認レスポンスかどうかを判定
---@param message string ユーザーメッセージ
---@return boolean
function M.is_approval_response(message)
  -- Input validation
  if not message or type(message) ~= "string" or message == "" then
    return false
  end

  -- 番号付きリスト形式での厳密なパターンマッチング
  -- 例: "1. allow_once - Allow this execution only"
  local patterns = {
    "^%d+%.%s*allow_once%s*%-",
    "^%d+%.%s*deny_once%s*%-",
    "^%d+%.%s*allow_for_session%s*%-",
    "^%d+%.%s*deny_for_session%s*%-",
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
  -- Input validation
  if not message or type(message) ~= "string" or message == "" then
    return nil
  end

  -- Extract the selected option from numbered list format
  -- Example: "1. allow_once - Allow this execution only"
  local action = nil

  -- 番号付きリスト形式での厳密なマッチング
  if message:match("^%d+%.%s*allow_once%s*%-") then
    action = "allow_once"
  elseif message:match("^%d+%.%s*deny_once%s*%-") then
    action = "deny_once"
  elseif message:match("^%d+%.%s*allow_for_session%s*%-") then
    action = "allow_for_session"
  elseif message:match("^%d+%.%s*deny_for_session%s*%-") then
    action = "deny_for_session"
  end

  if not action then
    return nil
  end

  -- Note: Tool name should be obtained from _pending_approval.tool
  -- rather than parsing from user message, as the approval UI is shown
  -- in the Assistant section, not in the user's editable area.
  return {
    action = action,
    tool = nil, -- Will be filled by caller from _pending_approval
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
