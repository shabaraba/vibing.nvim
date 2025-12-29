---@class Vibing.Domain.Session
---セッションエンティティ
---Claude Agent SDKとの会話セッションを表現
local Session = {}
Session.__index = Session

---新しいセッションを作成
---@param id string? セッションID
---@param mode string? 実行モード
---@param model string? 使用モデル
---@return Vibing.Domain.Session
function Session:new(id, mode, model)
  local instance = setmetatable({}, self)
  instance.id = id
  instance.mode = mode or "code"
  instance.model = model or "sonnet"
  instance.created_at = os.date("%Y-%m-%dT%H:%M:%S")
  instance.updated_at = nil
  return instance
end

---セッションIDを設定
---@param id string
function Session:set_id(id)
  self.id = id
  self.updated_at = os.date("%Y-%m-%dT%H:%M:%S")
end

---セッションが有効かチェック
---@return boolean
function Session:is_valid()
  return self.id ~= nil and self.id ~= ""
end

---セッション情報を辞書形式で取得
---@return table
function Session:to_dict()
  return {
    id = self.id,
    mode = self.mode,
    model = self.model,
    created_at = self.created_at,
    updated_at = self.updated_at,
  }
end

---辞書からセッションを復元
---@param dict table
---@return Vibing.Domain.Session
function Session.from_dict(dict)
  local instance = setmetatable({}, Session)
  instance.id = dict.id or dict.session_id
  instance.mode = dict.mode or "code"
  instance.model = dict.model or "sonnet"
  instance.created_at = dict.created_at or os.date("%Y-%m-%dT%H:%M:%S")
  instance.updated_at = dict.updated_at
  return instance
end

return Session
