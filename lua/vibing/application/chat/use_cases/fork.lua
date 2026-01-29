---@class Vibing.Application.Chat.UseCases.Fork
---チャットフォーク機能のUse Case
local M = {}

local notify = require("vibing.core.utils.notify")
local ChatSession = require("vibing.domain.chat.session")
local FileManager = require("vibing.presentation.chat.modules.file_manager")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
local Git = require("vibing.core.utils.git")

---ファイル名から-fork-N.vibingを生成
---@param source_path string
---@param save_dir string
---@return string fork_filename
local function generate_fork_filename(source_path, save_dir)
  local source_basename = vim.fn.fnamemodify(source_path, ":t:r") -- 拡張子なし
  local fork_number = 1
  local fork_filename = string.format("%s-fork-%d.vibing", source_basename, fork_number)
  local fork_path = save_dir .. fork_filename

  -- 重複チェック
  while vim.fn.filereadable(fork_path) == 1 do
    fork_number = fork_number + 1
    fork_filename = string.format("%s-fork-%d.vibing", source_basename, fork_number)
    fork_path = save_dir .. fork_filename
  end

  return fork_filename
end

---フロントマターをコピー（session_idは除外、forked_fromを追加）
---@param source_frontmatter table
---@param forked_from string
---@param config table
---@return table fork_frontmatter
local function copy_frontmatter(source_frontmatter, forked_from, config)
  return {
    ["vibing.nvim"] = true,
    session_id = "~",
    created_at = os.date("%Y-%m-%dT%H:%M:%S"),
    forked_from = forked_from,
    working_dir = source_frontmatter.working_dir,
    mode = source_frontmatter.mode or (config.agent and config.agent.default_mode or "code"),
    model = source_frontmatter.model or (config.agent and config.agent.default_model or "sonnet"),
    permission_mode = source_frontmatter.permission_mode
      or (config.permissions and config.permissions.mode or "acceptEdits"),
    permissions_allow = source_frontmatter.permissions_allow
      or (config.permissions and config.permissions.allow or {}),
    permissions_deny = source_frontmatter.permissions_deny or (config.permissions and config.permissions.deny or {}),
    language = source_frontmatter.language,
  }
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

  -- 自動保存
  if not auto_save_if_needed(chat_buffer.buf, chat_buffer.file_path) then
    return nil
  end

  local vibing = require("vibing")
  local config = vibing.get_config()

  -- フォーク元のフロントマターを読み込み
  local source_frontmatter = chat_buffer:parse_frontmatter()

  local forked_from = Git.to_display_path(chat_buffer.file_path)

  -- フロントマターをコピー
  local fork_frontmatter = copy_frontmatter(source_frontmatter, forked_from, config)

  local working_dir = source_frontmatter.working_dir

  local fork_session = ChatSession:new({
    frontmatter = fork_frontmatter,
    working_dir = working_dir,
  })

  -- fork_source_session_idを一時的に設定（Agent SDK呼び出し時に使用）
  fork_session._fork_source_session_id = chat_buffer.session_id

  -- ファイル名生成
  local save_dir = FileManager.get_save_directory(config.chat)
  vim.fn.mkdir(save_dir, "p")

  local fork_filename = generate_fork_filename(chat_buffer.file_path, save_dir)
  local fork_path = save_dir .. fork_filename

  fork_session:set_file_path(fork_path)

  -- 元チャットの会話履歴をフォークファイルにコピー
  local source_content = vim.fn.readfile(chat_buffer.file_path)
  local source_text = table.concat(source_content, "\n")
  local _, body = Frontmatter.parse(source_text)

  local fork_content = Frontmatter.serialize(fork_frontmatter, body)
  vim.fn.writefile(vim.split(fork_content, "\n"), fork_path)

  return fork_session
end

return M
