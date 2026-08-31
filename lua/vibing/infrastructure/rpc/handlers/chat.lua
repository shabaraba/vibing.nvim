---@class Vibing.Infrastructure.RPC.ChatHandler
---RPC handler for programmatic chat buffer creation (MCP tool `nvim_chat_create`)
local M = {}

local ChatConstants = require("vibing.core.constants.chat")
local FileManager = require("vibing.presentation.chat.modules.file_manager")

---新しいチャットバッファを作成する
---@param params {position?: string, working_dir?: string, from_bufnr?: number}
---@return {bufnr: number, file_path: string, working_dir: string?, position: string, saved: boolean}
function M.create_chat(params)
  params = params or {}

  local position = params.position or "back"
  if not ChatConstants.is_valid_position(position) then
    error(
      string.format(
        "Invalid position: %s (expected one of: %s)",
        tostring(position),
        table.concat(ChatConstants.POSITIONS, ", ")
      )
    )
  end

  local session = require("vibing.application.chat.use_cases.create_chat").execute({
    working_dir = params.working_dir,
  })
  -- background: ワーカーはユーザーが開いたチャットではないので、`view._current_buffer`
  -- （:VibingCancel などのフォールバック先）を奪わない
  local chat_buf = require("vibing.presentation.chat.view").render(session, position, { background = true })

  -- `:VibingChat`は最初の応答が返るまでファイルを書かない（buffer.lua:update_session_id）。
  -- 呼び出し元にファイルパスを返す以上、そのパスが存在しないのは嘘なので、forkと同じく
  -- 作成時点で保存する
  local saved = FileManager.save_buffer(chat_buf.buf)

  -- 作成した時点でリンクを張る。送信を待つ形でも記録はできるが、`from_bufnr` の渡し忘れが
  -- 「黙って関係が残らない」失敗になるので、関係が確定する最も早い時点で書く
  if params.from_bufnr then
    local ok, err = require("vibing.application.chat.orchestration_link").link(params.from_bufnr, chat_buf.buf)
    if not ok then
      require("vibing.core.utils.notify").warn(
        string.format("Created chat %d but could not link it: %s", chat_buf.buf, err or "unknown"),
        "Orchestration"
      )
    end
  end

  return {
    bufnr = chat_buf.buf,
    file_path = chat_buf.file_path,
    working_dir = session.working_dir,
    position = position,
    saved = saved,
  }
end

return M
