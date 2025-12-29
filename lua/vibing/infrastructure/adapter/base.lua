---@class Vibing.Infrastructure.BaseAdapter
---アダプターの基底クラス
local BaseAdapter = {}
BaseAdapter.__index = BaseAdapter

---新しいアダプターインスタンスを作成
---@param config table 設定
---@return Vibing.Infrastructure.BaseAdapter
function BaseAdapter:new(config)
  local instance = setmetatable({}, self)
  instance.config = config or {}
  instance.name = "base"
  return instance
end

---プロンプトを同期実行
---@param prompt string
---@param opts table?
---@return table
function BaseAdapter:execute(prompt, opts)
  error("execute() must be implemented by subclass")
end

---プロンプトをストリーミング実行
---@param prompt string
---@param opts table?
---@param on_chunk fun(chunk: string)
---@param on_done fun(response: table)
---@return string handle_id
function BaseAdapter:stream(prompt, opts, on_chunk, on_done)
  error("stream() must be implemented by subclass")
end

---実行中のリクエストをキャンセル
---@param handle_id string?
function BaseAdapter:cancel(handle_id)
  -- Default: no-op
end

---機能サポート状況を取得
---@param feature string
---@return boolean
function BaseAdapter:supports(feature)
  return false
end

return BaseAdapter
