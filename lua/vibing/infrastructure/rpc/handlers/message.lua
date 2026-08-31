---@class Vibing.Infrastructure.RPC.MessageHandler
---RPC handler for programmatic message sending
local M = {}

local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")

---Send message to chat buffer
---@param params {bufnr: number, message: string, sender?: string, from_bufnr?: number}
---@return {success: boolean, bufnr: number}
function M.send_message(params)
  if not params then
    error("Missing parameters")
  end

  -- `from_bufnr` は任意。必須にすると渡し忘れで送信そのものが失敗し、既存の
  -- オーケストレーション経路が壊れる。渡されなければリンクを張らないだけ（＝従来の動作）
  if params.from_bufnr then
    -- リンクは送信より前に書く必要がある（`update_frontmatter_list` はバッファを直接触るので、
    -- 宛先の応答が始まってから書くとストリーミングと競合する）。ただし送信が弾かれると
    -- 行われなかったやり取りの関係だけが永久に残るので、先に送信可能かを確かめる
    ProgrammaticSender.validate(params.bufnr, params.message)

    local ok, err = require("vibing.application.chat.orchestration_link").link(params.from_bufnr, params.bufnr)
    -- リンクは記録であって、失敗が送信を止める理由にはならない。片方だけ書けた状態でも
    -- リネーム同期は残った側で動く
    if not ok then
      require("vibing.core.utils.notify").warn(
        string.format("Could not link chats %d -> %d: %s", params.from_bufnr, params.bufnr, err or "unknown"),
        "Orchestration"
      )
    end
  end

  -- ProgrammaticSender.send already validates parameters
  return ProgrammaticSender.send(params.bufnr, params.message, params.sender)
end

return M
