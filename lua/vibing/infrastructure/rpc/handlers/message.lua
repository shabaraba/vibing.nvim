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
  local result = ProgrammaticSender.send(params.bufnr, params.message, params.sender)

  -- 送ったという事実そのものを購読の登録として扱う。宛先が応答を終えたら送信元に
  -- 「読みに行け」とだけ伝わる（application/chat/completion_notifier.lua）。同時に、逆向きの
  -- watchdog エッジ（宛先が送信元の完了を待っていた分）はこの配達で用済みになるので消える。
  --
  -- 送信の**後**に張るのが要点。上の `validate` は「応答中」を弾くが、その判定とここの間には
  -- リンク書き込み（バッファ編集と2ファイルの保存）が挟まるので状態は変わりうるし、
  -- `send_message()` が false を返す経路もある。先に張ると、送っていないメッセージについて
  -- 「相手が終わった、読みに行け」だけが後から届く。
  --
  -- 遅すぎることはない: CLIの起動は非同期で、宛先の完了は `vim.schedule` 経由なので
  -- この関数が返るより先には走らない
  if params.from_bufnr and result and result.success then
    require("vibing.application.chat.completion_notifier").on_message_sent(params.from_bufnr, params.bufnr)
  end

  return result
end

return M
