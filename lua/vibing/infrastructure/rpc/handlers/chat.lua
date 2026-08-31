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
  FileManager.save_buffer(chat_buf.buf)

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

    -- 作成でも購読を張る。送信だけを登録にすると、ブリーフに `from_bufnr` を渡し忘れたときに
    -- 「黙って通知が来ない」で終わる。作ってメッセージを送らないケースは無いので、
    -- 早い方に寄せておくほうが渡し忘れに強い。
    --
    -- リンクの書き込みが失敗しても購読は張る（意図的な非対称）。frontmatter が書けないと
    -- ワーカーは「誰に報告すればいいか」の行を得られない（`send_message` が
    -- `orchestrated_by` を読むため）が、オーケストレーター側が完了を知る手段まで一緒に
    -- 失う理由はない。通知はインメモリで、frontmatter を必要としない
    require("vibing.application.chat.completion_notifier").subscribe(params.from_bufnr, chat_buf.buf)
  end

  return {
    bufnr = chat_buf.buf,
    file_path = chat_buf.file_path,
    working_dir = session.working_dir,
    position = position,
    -- リンク書き込みはバッファを変更して保存し直すので、`saved` はその**後**に見る。
    -- 先にスナップショットすると、リンクの無いディスク上のコピーに対して true を返しうる
    saved = not vim.bo[chat_buf.buf].modified,
  }
end

return M
