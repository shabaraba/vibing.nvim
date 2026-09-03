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
---元チャットにも `## summary` が残るので、あとから `:VibingSetFileTitle` がそれを入力に使える。
---要約を新しいチャットの**未送信 User セクションに直接書く**のは、モデルに Read で元ファイルを
---読ませるより安いから: ツール呼び出しは1回ごとに全コンテキストを再読し、読んだファイルの
---全文は以後のリクエストにも残る。要約をユーザーメッセージの先頭に置けば、初回リクエストの
---入力に数k足すだけで済む。
local M = {}

local notify = require("vibing.core.utils.notify")
local ChatSession = require("vibing.domain.chat.session")
local FileManager = require("vibing.presentation.chat.modules.file_manager")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
local Git = require("vibing.core.utils.git")
local InheritedFrontmatter = require("vibing.application.chat.inherited_frontmatter")
local Timestamp = require("vibing.core.utils.timestamp")
local Fs = require("vibing.core.utils.fs")

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

---新しいチャットファイルの本文（frontmatter の後ろ）を組み立てる。
---
---`renderer.init_content` が空のチャットに書く並び（`# Vibing Chat` / `---` / 未送信ヘッダー）
---をそのまま踏み、未送信 User セクションの中に前置きと要約を置く。末尾は空行で終え、
---ユーザーが続きの指示をそこに書いて `<CR>` で送れるようにする。
---@param summary_body string `strip_summary_heading` 済みの要約本文
---@param source_display_path string 元チャットの表示パス（gitルート相対）
---@return string body
function M.build_body(summary_body, source_display_path)
  local lines = {
    "",
    "# Vibing Chat",
    "",
    "---",
    "",
    Timestamp.create_unsent_user_header(),
    "",
    string.format(M.LEAD_IN, source_display_path),
    "",
  }
  for _, line in ipairs(vim.split(summary_body, "\n", { plain = true })) do
    table.insert(lines, line)
  end
  table.insert(lines, "")
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

---ファイル名は fork と同じ規則で `<元の名前>-handoff-N.md`。
---
---`generate_unique_filename` の `chat-<timestamp>-...` にしないのは、どのチャットから
---引き継いだかがファイル一覧で分かるほうが、要約だけ持った新しいチャットには役に立つから。
---@param source_path string
---@param save_dir string
---@return string filename
local function generate_handoff_filename(source_path, save_dir)
  local source_basename = vim.fn.fnamemodify(source_path, ":t:r")
  local n = 1
  local filename = string.format("%s-handoff-%d.md", source_basename, n)
  while vim.fn.filereadable(vim.fs.joinpath(save_dir, filename)) == 1 do
    n = n + 1
    filename = string.format("%s-handoff-%d.md", source_basename, n)
  end
  return filename
end

---引き継ぎ先の frontmatter を作る。
---
---`InheritedFrontmatter.from_source` で fork / subagent chat と同じ範囲（model / effort /
---permissions / working_dir / language）を引き継ぎ、`session_id` だけは**必ず空にする**。
---引き継いでしまうと `--resume` で元の会話履歴がそのまま付いてきて、コンテキストを減らす
---という目的そのものが消える。出自は `continued_from` に残す（`forked_from` を流用しない:
---あれは `send_message` に `--fork-session` を出させるフラグでもある）。
---@param source_frontmatter table
---@param continued_from string 元チャットの表示パス
---@param config table
---@return table
function M._build_frontmatter(source_frontmatter, continued_from, config)
  local frontmatter = InheritedFrontmatter.from_source(source_frontmatter, config)
  frontmatter.session_id = "~"
  frontmatter.continued_from = continued_from
  return frontmatter
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

  local source_frontmatter = chat_buffer:parse_frontmatter()
  if not source_frontmatter then
    return nil, "Failed to parse source frontmatter"
  end

  local vibing = require("vibing")
  local config = vibing.get_config()

  local continued_from = Git.to_display_path(chat_buffer.file_path)
  local frontmatter = M._build_frontmatter(source_frontmatter, continued_from, config)

  local save_dir = FileManager.get_save_directory(config.chat)
  Fs.ensure_dir(save_dir)
  local file_path = vim.fs.joinpath(save_dir, generate_handoff_filename(chat_buffer.file_path, save_dir))

  local content = Frontmatter.serialize(frontmatter, M.build_body(summary_body, continued_from))
  if vim.fn.writefile(vim.split(content, "\n", { plain = true }), file_path) ~= 0 then
    return nil, "Failed to write handoff file: " .. file_path
  end

  local session = ChatSession:new({
    frontmatter = frontmatter,
    working_dir = source_frontmatter.working_dir,
  })
  session:set_file_path(file_path)
  return session
end

---元チャットを保存する。要約が書き込まれたバッファを保存しないと、新しいチャットの前置きが
---指すファイルに `## summary` が無いままになる。失敗しても引き継ぎ自体は続ける: 要約は
---新しいチャットに持っていってあるので、元ファイルの保存が遅れても失うものはない。
---@param chat_buffer Vibing.ChatBuffer
local function save_source(chat_buffer)
  local buf = chat_buffer.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local ok, err = pcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent! write")
    end)
  end)
  if not ok then
    notify.warn("Failed to save source chat: " .. tostring(err))
  end
end

---要約を生成し、それを引き継いだ新しいチャットセッションを作る（非同期）。
---
---`opts.on_done` は成功なら session、失敗なら nil と理由で**必ず1回**呼ばれる。
---要約の生成に失敗した場合、その内訳は `generate_and_insert_summary` 側が通知済み。
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

  local UseCase = require("vibing.application.chat.use_case")
  UseCase.generate_and_insert_summary(chat_buffer, {
    on_done = function(ok, err)
      if not ok then
        return on_done(nil, err or "Summary generation failed")
      end

      local SummaryInserter = require("vibing.presentation.chat.modules.summary_inserter")
      local summary = SummaryInserter.extract(chat_buffer.buf)
      if not summary then
        notify.error("Summary was generated but could not be read back from the chat buffer")
        return on_done(nil, "Summary could not be read back from the chat buffer")
      end

      save_source(chat_buffer)

      local session, create_err = M.create_session(chat_buffer, summary)
      if not session then
        notify.error(create_err or "Failed to create handoff chat")
        return on_done(nil, create_err)
      end
      on_done(session)
    end,
  })
end

return M
