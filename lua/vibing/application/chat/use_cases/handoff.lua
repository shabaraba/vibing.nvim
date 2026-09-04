---@class Vibing.Application.Chat.UseCases.Handoff
---現在のチャットの要約を引き継いだ新規チャットを作る Use Case（`:VibingChatHandoff` の実体）。
---
---fork と違ってセッションは引き継がない。fork は `--fork-session` で会話履歴ごと分岐するので
---新しいチャットも元と同じサイズのコンテキストから始まるが、ここは「履歴を捨てて要約だけ
---持っていく」ためのもので、目的はコンテキストを床（system prompt + ツール定義 + CLAUDE.md）
---まで戻すことにある。1ターンのコストは requests × context なので、長くなったチャットを
---続けるより、要約数kだけ持った新しいチャットで続けるほうが以後の全リクエストが安い
---（`handbook/configuration.md` → "Token Usage"）。
---
---要約は `:VibingSummarize` と同じ経路（`use_case.generate_and_insert_summary`）で作る。
---ただし**バッファに既に `## summary` があるならそれを使い、生成は省く**。要約の生成は
---会話全体を読ませる1リクエストで、引き継ぎで削りたいコストそのものだから、直前に
---`:VibingSummarize` を走らせたユーザーに同じ請求を二度させる理由がない。古い要約を
---引き継ぎたくない場合は `:VibingSummarize` で更新してから実行すればよい（更新は
---`insert_or_update` が同じセクションを上書きする）。
---元チャットにも `## summary` が残るので、あとから `:VibingSetFileTitle` がそれを入力に使える。
---要約を新しいチャットの**未送信 User セクションに直接書く**のは、モデルに Read で元ファイルを
---読ませるより安いから: ツール呼び出しは1回ごとに全コンテキストを再読し、読んだファイルの
---全文は以後のリクエストにも残る。要約をユーザーメッセージの先頭に置けば、初回リクエストの
---入力に数k足すだけで済む。
local M = {}

local notify = require("vibing.core.utils.notify")
local ContinuationChat = require("vibing.application.chat.use_cases.continuation_chat")
local Git = require("vibing.core.utils.git")

---新しいチャットの最初のメッセージに置く前置き。`%s` は元チャットの表示パス。
---
---英語なのは auto_resume の継続プロンプトと同じ理由で、応答言語は system prompt の
---language 指示が決めるので、ここで合わせる必要がない。「必要なときだけ元ファイルを読め」と
---書くのは、要約で足りる場面で元の transcript を丸ごと Read されると、引き継ぎで減らした
---コンテキストがその1回で元に戻るため。
M.LEAD_IN = "Continuing from the vibing.nvim chat `%s`. Its summary follows; read that file "
  .. "only if you need detail the summary does not carry."

---`## summary` の見出し行を落として本文だけにする。
---
---見出しを残すと、新しいチャットの User セクションの中に `## ` で始まる行が入る。
---`timestamp.parse_header` は `## summary` をヘッダーとして読まないので会話の切り出しは
---壊れないが、`summary_inserter` が次の `:VibingSummarize` で `## summary` を探すときに
---ヘッダー領域の外にあるこの行を拾う余地を残さないほうがよい。
---@param summary string `## summary` で始まる要約
---@return string? body 見出しを除いた本文。空なら nil
function M.strip_summary_heading(summary)
  if type(summary) ~= "string" then
    return nil
  end
  local body = summary:gsub("^%s*##%s*[Ss][Uu][Mm][Mm][Aa][Rr][Yy][^\n]*\n?", "", 1)
  body = vim.trim(body)
  if body == "" then
    return nil
  end
  return body
end

---未送信 User セクションに入る中身（前置き + 要約）。
---@param summary_body string `strip_summary_heading` 済みの要約本文
---@param source_display_path string 元チャットの表示パス（gitルート相対）
---@return string
local function message_body(summary_body, source_display_path)
  return string.format(M.LEAD_IN, source_display_path) .. "\n\n" .. summary_body
end

---新しいチャットファイルの本文（frontmatter の後ろ）を組み立てる。
---
---並び（`# Vibing Chat` / `---` / 未送信ヘッダー / 末尾の空行）は `continuation_chat` が持つ。
---ここが足すのは前置きと要約だけ。
---@param summary_body string `strip_summary_heading` 済みの要約本文
---@param source_display_path string 元チャットの表示パス（gitルート相対）
---@return string body
function M.build_body(summary_body, source_display_path)
  return ContinuationChat.build_body(message_body(summary_body, source_display_path))
end

---要約を持った新しいチャットファイルを書き、そのセッションを返す（同期）。
---@param chat_buffer Vibing.ChatBuffer 引き継ぎ元
---@param summary string `## summary` で始まる要約
---@return Vibing.ChatSession? session
---@return string? error
function M.create_session(chat_buffer, summary)
  if not chat_buffer or not chat_buffer.file_path then
    return nil, "No valid chat buffer to hand off"
  end

  local summary_body = M.strip_summary_heading(summary)
  if not summary_body then
    return nil, "Summary is empty"
  end

  return ContinuationChat.create(chat_buffer, {
    body = message_body(summary_body, Git.to_display_path(chat_buffer.file_path)),
    suffix = "handoff",
  })
end

---要約を生成し、それを引き継いだ新しいチャットセッションを作る（非同期）。
---
---`opts.on_done` は成功なら session、失敗なら nil と理由で**必ず1回**呼ばれる。
---要約の生成に失敗した場合、その内訳は `generate_and_insert_summary` 側が通知済み。
---既に `## summary` があるチャットでは生成を飛ばすので、この関数は同期的に完了しうる。
---@param chat_buffer Vibing.ChatBuffer
---@param opts {on_done: fun(session: Vibing.ChatSession?, err: string?)}
function M.execute(chat_buffer, opts)
  local on_done = opts and opts.on_done or function() end

  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    notify.error("No valid chat buffer to hand off")
    return on_done(nil, "No valid chat buffer to hand off")
  end
  if not chat_buffer.file_path then
    notify.error("This chat has no file to hand off from")
    return on_done(nil, "This chat has no file to hand off from")
  end

  local SummaryInserter = require("vibing.presentation.chat.modules.summary_inserter")

  ---要約が手元にある状態からの後半。生成した場合も再利用した場合もここを通る。
  ---@param summary string
  local function hand_off_with(summary)
    -- 要約が書き込まれたバッファを保存しないと、新しいチャットの前置きが指すファイルに
    -- `## summary` が無いままになる
    ContinuationChat.save_source(chat_buffer.buf)

    local session, create_err = M.create_session(chat_buffer, summary)
    if not session then
      notify.error(create_err or "Failed to create handoff chat")
      return on_done(nil, create_err)
    end
    on_done(session)
  end

  local existing = SummaryInserter.extract(chat_buffer.buf)
  if existing then
    notify.info("Reusing this chat's ## summary (run :VibingSummarize first to refresh it)")
    return hand_off_with(existing)
  end

  local UseCase = require("vibing.application.chat.use_case")
  UseCase.generate_and_insert_summary(chat_buffer, {
    on_done = function(ok, err)
      if not ok then
        return on_done(nil, err or "Summary generation failed")
      end

      local summary = SummaryInserter.extract(chat_buffer.buf)
      if not summary then
        notify.error("Summary was generated but could not be read back from the chat buffer")
        return on_done(nil, "Summary could not be read back from the chat buffer")
      end

      hand_off_with(summary)
    end,
  })
end

return M
