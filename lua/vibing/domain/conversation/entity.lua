---@class Vibing.Domain.Conversation
---会話エンティティ
---チャットの会話履歴を管理
local Conversation = {}
Conversation.__index = Conversation

local Message = require("vibing.domain.chat.message")

---新しい会話を作成
---@return Vibing.Domain.Conversation
function Conversation:new()
  local instance = setmetatable({}, self)
  instance.messages = {}
  return instance
end

---メッセージを追加
---@param role "user"|"assistant"|"system"
---@param content string
---@return Vibing.Domain.Message
function Conversation:add_message(role, content)
  local msg = Message:new(role, content)
  table.insert(self.messages, msg)
  return msg
end

---最後のメッセージを取得
---@return Vibing.Domain.Message?
function Conversation:last_message()
  if #self.messages == 0 then
    return nil
  end
  return self.messages[#self.messages]
end

---ユーザーメッセージの数を取得
---@return number
function Conversation:user_message_count()
  local count = 0
  for _, msg in ipairs(self.messages) do
    if msg.role == "user" then
      count = count + 1
    end
  end
  return count
end

---会話が空かチェック
---@return boolean
function Conversation:is_empty()
  return #self.messages == 0
end

---会話をクリア
function Conversation:clear()
  self.messages = {}
end

---Agent SDK形式に変換
---@return table[]
function Conversation:to_sdk_format()
  local result = {}
  for _, msg in ipairs(self.messages) do
    table.insert(result, msg:to_dict())
  end
  return result
end

return Conversation
