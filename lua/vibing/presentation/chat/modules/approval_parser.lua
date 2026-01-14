---@class Vibing.ApprovalParser
---承認レスポンスをパースするモジュール
local M = {}

-- 承認アクションのパターンマップ（番号付きリスト形式）
-- 例: "1. allow_once - Allow this execution only"
-- 引用記号（> ）や先頭の空白も許容
local APPROVAL_PATTERNS = {
  allow_once = "^[>%s]*%d+%.%s*allow_once%s*%-",
  deny_once = "^[>%s]*%d+%.%s*deny_once%s*%-",
  allow_for_session = "^[>%s]*%d+%.%s*allow_for_session%s*%-",
  deny_for_session = "^[>%s]*%d+%.%s*deny_for_session%s*%-",
}

---承認レスポンスかどうかを判定
---@param message string ユーザーメッセージ
---@return boolean
function M.is_approval_response(message)
  if not message or type(message) ~= "string" or message == "" then
    return false
  end

  for line in message:gmatch("[^\r\n]+") do
    for _, pattern in pairs(APPROVAL_PATTERNS) do
      if line:match(pattern) then
        return true
      end
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

  -- Check each line and find which approval action matches
  for line in message:gmatch("[^\r\n]+") do
    for action, pattern in pairs(APPROVAL_PATTERNS) do
      if line:match(pattern) then
        -- Note: Tool name should be obtained from _pending_approval.tool
        -- rather than parsing from user message, as the approval UI is shown
        -- in the User section (after our refactoring).
        return {
          action = action,
          tool = nil, -- Will be filled by caller from _pending_approval
        }
      end
    end
  end

  return nil
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
