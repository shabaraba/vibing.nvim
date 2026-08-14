---@class Vibing.Core.ChatConstants
---チャットバッファ生成にまつわる定数定義
---
---`:VibingChat`/`:VibingChatFork`/`:VibingSubagentChat`（controllerの検証とinit.luaの補完）と、
---MCPツール`nvim_chat_create`のRPCハンドラが同じ位置指定を受け付ける必要があるため、
---どこかにlocalで持たせず、ここを参照させる。
local M = {}

---引数として受け付けるウィンドウ位置
---`back`はウィンドウを作らずバッファだけを作る（`window_manager.create_window`がnilを返す）
---
---`config.chat.window.position` はこれに加えて`float`も取るが、コマンド引数としては元から
---受け付けていない（`window_manager`のフォールバック分岐でのみ到達する）。ここに足すと
---`:VibingChat float`の挙動が変わるので、設定専用のままにしてある
---@type string[]
M.POSITIONS = { "current", "right", "left", "top", "bottom", "back" }

---ウィンドウ位置が有効かチェック
---@param position string
---@return boolean
function M.is_valid_position(position)
  return vim.tbl_contains(M.POSITIONS, position)
end

return M
