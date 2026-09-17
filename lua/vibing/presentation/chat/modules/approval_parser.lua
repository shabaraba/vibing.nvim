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

-- `generate_response_message` はここにあった。承認から模型に渡す文を組み立てる関数が、実際に
-- 使われている `approval_decision.retry_message` とは別の文面で2つ目として存在していた
-- （本番コードからの参照はゼロで、自分のspecだけが呼んでいた）。まさに
-- `.claude/rules/permissions.md` が禁じている「承認が意味することの2つ目の実装」なので、
-- #778 の抽出と一緒に消した。このパーサはバッファの行を4択のどれかに読むことだけを持つ。

return M
