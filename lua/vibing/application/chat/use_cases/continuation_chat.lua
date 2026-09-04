---@class Vibing.Application.Chat.UseCases.ContinuationChat
---「このチャットを引き継ぐ新しいチャットを1本作る」の共通部分。
---
---handoff（要約を持っていく）と carry_over（未送信の本文だけ持っていく）は、User セクションに
---何を入れるかだけが違い、frontmatter の引き継ぎ方・ファイル名の付け方・書き出し方・元チャットの
---保存は同じ。別々に書いていると同じ判断が2箇所に散り、実際に割れる: `save_source` は
---`vim.cmd("silent! write")` と `vim.cmd.write({ bang = true })` の2実装になっていた（前者は
---ファイル名変更後の2回目の保存で E13 になる）。
---
---`session_id` を必ず空にするのはここの責務にしてある。引き継いでしまうと `--resume` で元の
---会話履歴がそのまま付いてきて、コンテキストを床に戻すという目的そのものが消えるので、
---呼び出し側ごとに書くたぐいの条件ではない。出自は `continued_from` に残す（`forked_from` を
---流用しない: あれは `send_message` に `--fork-session` を出させるフラグでもある）。
local M = {}

local ChatSession = require("vibing.domain.chat.session")
local FileManager = require("vibing.presentation.chat.modules.file_manager")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
local Fs = require("vibing.core.utils.fs")
local Git = require("vibing.core.utils.git")
local InheritedFrontmatter = require("vibing.application.chat.inherited_frontmatter")
local Timestamp = require("vibing.core.utils.timestamp")
local notify = require("vibing.core.utils.notify")

---新しいチャットファイルの本文（frontmatter の後ろ）を組み立てる。
---
---`renderer.init_content` が空のチャットに書く並び（`# Vibing Chat` / `---` / 未送信ヘッダー）
---をそのまま踏み、未送信 User セクションの中に `body` を置く。末尾を空行で終えるのは、
---ユーザーが続きの指示をそこに書いて `<CR>` で送れるようにするため
---@param body string 未送信 User セクションに入れる本文
---@return string
function M.build_body(body)
  local lines = {
    "",
    "# Vibing Chat",
    "",
    "---",
    "",
    Timestamp.create_unsent_user_header(),
    "",
  }
  vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
  table.insert(lines, "")
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

---ファイル名は `<元の名前>-<suffix>-N.md`。
---
---`generate_unique_filename` の `chat-<timestamp>-...` にしないのは、どのチャットから
---引き継いだかがファイル一覧で分かるほうが、履歴を持たない新しいチャットには役に立つから
---@param source_path string
---@param save_dir string
---@param suffix string
---@return string filename
local function generate_filename(source_path, save_dir, suffix)
  local base = vim.fn.fnamemodify(source_path, ":t:r")
  local n = 1
  local filename = string.format("%s-%s-%d.md", base, suffix, n)
  while vim.fn.filereadable(vim.fs.joinpath(save_dir, filename)) == 1 do
    n = n + 1
    filename = string.format("%s-%s-%d.md", base, suffix, n)
  end
  return filename
end

---引き継ぎ先のチャットファイルを書き、そのセッションを返す（同期）。
---@param chat_buffer Vibing.ChatBuffer 引き継ぎ元
---@param opts {body: string, suffix: string}
---@return Vibing.ChatSession? session
---@return string? error
function M.create(chat_buffer, opts)
  if not chat_buffer or not chat_buffer.file_path then
    return nil, "This chat has no file to continue from"
  end

  local source_frontmatter = chat_buffer:parse_frontmatter()
  if not source_frontmatter then
    return nil, "Failed to parse source frontmatter"
  end

  local config = require("vibing").get_config()
  local frontmatter = InheritedFrontmatter.from_source(source_frontmatter, config)
  frontmatter.session_id = "~"
  frontmatter.continued_from = Git.to_display_path(chat_buffer.file_path)

  local save_dir = FileManager.get_save_directory(config.chat)
  Fs.ensure_dir(save_dir)
  local file_path = vim.fs.joinpath(save_dir, generate_filename(chat_buffer.file_path, save_dir, opts.suffix))

  local content = Frontmatter.serialize(frontmatter, M.build_body(opts.body))
  if vim.fn.writefile(vim.split(content, "\n", { plain = true }), file_path) ~= 0 then
    return nil, "Failed to write the continuation file: " .. file_path
  end

  local session = ChatSession:new({
    frontmatter = frontmatter,
    working_dir = source_frontmatter.working_dir,
  })
  session:set_file_path(file_path)
  return session
end

---元チャットを保存する。
---
---失敗しても引き継ぎ自体は続ける: 持っていく内容は新しいチャットのファイルに書き終えてあるので、
---元ファイルの保存が遅れても失うものはない
---@param buf number
function M.save_source(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local ok, err = pcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd.write({ bang = true, mods = { silent = true } })
    end)
  end)
  if not ok then
    notify.warn("Failed to save source chat: " .. tostring(err))
  end
end

return M
