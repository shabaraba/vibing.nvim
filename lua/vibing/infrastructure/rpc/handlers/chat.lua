---@class Vibing.Infrastructure.RPC.ChatHandler
---RPC handler for programmatic chat buffer creation (MCP tool `nvim_chat_create`)
local M = {}

local ChatConstants = require("vibing.core.constants.chat")

---作成したチャットをその場でディスクに書き出す
---`:VibingChat`は最初の応答が返るまでファイルを書かない（buffer.lua:update_session_id）。
---呼び出し元にファイルパスを返す以上、そのパスが存在しないのは嘘なので、forkと同じく
---作成時点で保存する
---@param bufnr number
---@return boolean saved
local function save_now(bufnr)
  local ok = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("silent write")
  end)
  -- `write`はエラーを黙って飲むことがあるので、pcallの成否だけでなくmodifiedも確認する
  return ok and not vim.bo[bufnr].modified
end

---新しいチャットバッファを作成する
---@param params {position?: string, working_dir?: string}
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

  return {
    bufnr = chat_buf.buf,
    file_path = chat_buf.file_path,
    working_dir = session.working_dir,
    position = position,
    saved = save_now(chat_buf.buf),
  }
end

return M
