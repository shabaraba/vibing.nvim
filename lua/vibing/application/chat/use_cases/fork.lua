---@class Vibing.Application.Chat.UseCases.Fork
---チャットフォーク機能のUse Case
local M = {}

local notify = require("vibing.core.utils.notify")
local ChatSession = require("vibing.domain.chat.session")
local FileManager = require("vibing.presentation.chat.modules.file_manager")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
local Git = require("vibing.core.utils.git")
local InheritedFrontmatter = require("vibing.application.chat.inherited_frontmatter")
local SubagentMarker = require("vibing.infrastructure.adapter.modules.subagent_marker")

---ファイル名から-fork-N.mdを生成
---@param source_path string
---@param save_dir string
---@return string fork_filename
local function generate_fork_filename(source_path, save_dir)
  local source_basename = vim.fn.fnamemodify(source_path, ":t:r")
  local fork_number = 1
  local fork_filename = string.format("%s-fork-%d.md", source_basename, fork_number)
  local fork_path = vim.fs.joinpath(save_dir, fork_filename)

  while vim.fn.filereadable(fork_path) == 1 do
    fork_number = fork_number + 1
    fork_filename = string.format("%s-fork-%d.md", source_basename, fork_number)
    fork_path = vim.fs.joinpath(save_dir, fork_filename)
  end

  return fork_filename
end

---フロントマターをコピー（session_idはフォーク元を引き継ぎ、forked_fromを追加）
---@param source_frontmatter table
---@param forked_from string
---@param config table
---@return table fork_frontmatter
function M._copy_frontmatter(source_frontmatter, forked_from, config)
  local fork_frontmatter = InheritedFrontmatter.from_source(source_frontmatter, config)
  -- session_idはフォーク元のまま渡す。--fork-sessionフラグでforkSession: trueが設定され、
  -- 初回メッセージで新しいsession_idが付与される
  fork_frontmatter.forked_from = forked_from
  return fork_frontmatter
end

---バッファを自動保存
---@param bufnr number
---@param file_path string
---@return boolean success
local function auto_save_if_needed(bufnr, file_path)
  if vim.fn.filereadable(file_path) == 0 or vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
    local ok, err = pcall(function()
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent! write")
      end)
    end)
    if not ok then
      notify.error("Failed to save source file: " .. tostring(err))
      return false
    end
    notify.info("Auto-saved source file before forking")
  end
  return true
end

---現在のチャットをフォーク
---@param chat_buffer Vibing.ChatBuffer フォーク元のチャットバッファ
---@return Vibing.ChatSession? fork_session
function M.execute(chat_buffer)
  if not chat_buffer or not chat_buffer.file_path then
    notify.error("No valid chat buffer to fork")
    return nil
  end

  if not auto_save_if_needed(chat_buffer.buf, chat_buffer.file_path) then
    return nil
  end

  local vibing = require("vibing")
  local config = vibing.get_config()

  -- ソースファイルを1回だけ読み込み、frontmatterとbodyを同時に取得
  local ok, source_content = pcall(vim.fn.readfile, chat_buffer.file_path)
  if not ok or not source_content then
    notify.error("Failed to read source file: " .. tostring(source_content))
    return nil
  end
  local source_text = table.concat(source_content, "\n")
  local source_frontmatter, body = Frontmatter.parse(source_text)

  if not source_frontmatter then
    notify.error("Failed to parse source frontmatter")
    return nil
  end

  local forked_from = Git.to_display_path(chat_buffer.file_path)
  local fork_frontmatter = M._copy_frontmatter(source_frontmatter, forked_from, config)

  local fork_session = ChatSession:new({
    session_id = chat_buffer.session_id,
    frontmatter = fork_frontmatter,
    working_dir = source_frontmatter.working_dir,
  })

  local save_dir = FileManager.get_save_directory(config.chat)
  vim.fn.mkdir(save_dir, "p")

  local fork_filename = generate_fork_filename(chat_buffer.file_path, save_dir)
  local fork_path = vim.fs.joinpath(save_dir, fork_filename)

  fork_session:set_file_path(fork_path)

  -- subagentマーカーは持ち込まない。forkは初回送信で別のsession_idへ分岐するが、
  -- subagentのtranscriptは元のsession配下にあるので、分岐後のバッファからそのagentを
  -- 選ばせても "No transcript found for agent ID" になるだけ（architecture.md「Subagent Chat」）
  local fork_body = SubagentMarker.strip(body or "")

  local fork_content = Frontmatter.serialize(fork_frontmatter, fork_body)
  local write_result = vim.fn.writefile(vim.split(fork_content, "\n"), fork_path)
  if write_result ~= 0 then
    notify.error("Failed to write fork file: " .. fork_path)
    return nil
  end

  return fork_session
end

return M
