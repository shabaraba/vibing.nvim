---@class Vibing.Domain.InlineTask
---インラインタスクエンティティ
---fix, feat, explain等のインラインアクションを表現
local InlineTask = {}
InlineTask.__index = InlineTask

---新しいタスクを作成
---@param action string アクション名
---@param context string コンテキスト
---@param additional_prompt string? 追加プロンプト
---@return Vibing.Domain.InlineTask
function InlineTask:new(action, context, additional_prompt)
  local instance = setmetatable({}, self)
  instance.id = string.format("%d_%d", vim.uv.hrtime(), math.random(1000, 9999))
  instance.action = action
  instance.context = context
  instance.additional_prompt = additional_prompt or ""
  instance.status = "pending"
  instance.created_at = os.date("%Y-%m-%dT%H:%M:%S")
  instance.started_at = nil
  instance.completed_at = nil
  instance.error = nil
  return instance
end

---タスクを開始
function InlineTask:start()
  self.status = "running"
  self.started_at = os.date("%Y-%m-%dT%H:%M:%S")
end

---タスクを完了
function InlineTask:complete()
  self.status = "completed"
  self.completed_at = os.date("%Y-%m-%dT%H:%M:%S")
end

---タスクをエラー終了
---@param error_message string
function InlineTask:fail(error_message)
  self.status = "failed"
  self.error = error_message
  self.completed_at = os.date("%Y-%m-%dT%H:%M:%S")
end

---タスクがキャンセル可能かチェック
---@return boolean
function InlineTask:is_cancellable()
  return self.status == "pending" or self.status == "running"
end

---タスク情報を辞書形式で取得
---@return table
function InlineTask:to_dict()
  return {
    id = self.id,
    action = self.action,
    context = self.context,
    additional_prompt = self.additional_prompt,
    status = self.status,
    created_at = self.created_at,
    started_at = self.started_at,
    completed_at = self.completed_at,
    error = self.error,
  }
end

return InlineTask
