---@class Vibing.ChatHandler.NewSession
local M = {}

---セッションを完全にリセット
---@param args string コマンド引数（未使用）
---@param chat_buffer table チャットバッファインスタンス
---@return boolean handled
---@return string? expanded
function M.execute(args, chat_buffer)
  -- セッションIDをクリア
  chat_buffer.session_id = nil

  -- フロントマターのセッションIDを削除
  chat_buffer:update_frontmatter("session_id", "~", false)

  -- アダプターのセッション管理をクリーンアップ
  local vibing = require("vibing")
  local adapter = vibing.get_adapter()
  if adapter and adapter.supports and adapter:supports("session") then
    adapter:cleanup_stale_sessions()
  end

  -- ユーザーに通知
  vim.notify("[vibing] Session reset. Next message will start a new session.", vim.log.levels.INFO)

  return true, nil
end

return M
