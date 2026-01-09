---@class Vibing.Presentation.ChatView
---チャット機能のView層ファサード
---ChatBufferインスタンスの管理とセッションとの紐付けを担当
local M = {}

local ChatBuffer = require("vibing.presentation.chat.buffer")
local notify = require("vibing.core.utils.notify")

---現在アクティブなチャットバッファ（:VibingChatで作成）
---@type Vibing.ChatBuffer?
M._current_buffer = nil

---:eで開いた.vibingファイルのアタッチ済みバッファ（バッファ番号 → ChatBuffer）
---@type table<number, Vibing.ChatBuffer>
M._attached_buffers = {}

---セッションをチャットバッファに描画
---@param session Vibing.ChatSession
---@param position? string 位置指定（current|right|left）
function M.render(session, position)
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- 毎回新規バッファを作成（既存バッファを再利用しない）
  local chat_buf = ChatBuffer:new(config.chat)
  M._current_buffer = chat_buf

  -- セッションデータをバッファに反映
  if session.file_path then
    chat_buf.file_path = session.file_path
    chat_buf.session_id = session.session_id
  end

  -- 位置指定が指定されている場合は一時的にオーバーライド
  if position then
    chat_buf.config.window.position = position
  end

  chat_buf:open()

  -- セッションの内容をバッファに書き込む
  if session.file_path and vim.fn.filereadable(session.file_path) == 1 then
    local content = vim.fn.readfile(session.file_path)
    vim.api.nvim_buf_set_lines(chat_buf.buf, 0, -1, false, content)

    -- PreviewDataを復元（Modified Filesとsaved_contents）
    local ModifiedFilesParser = require("vibing.presentation.chat.modules.modified_files_parser")
    local modified_files = ModifiedFilesParser.parse_latest_modified_files(chat_buf.buf)
    if #modified_files > 0 then
      local GitBlobStorage = require("vibing.infrastructure.storage.git_blob")
      local PreviewData = require("vibing.presentation.chat.modules.preview_data")
      local saved_hashes = session.frontmatter.saved_hashes or {}
      local saved_contents = GitBlobStorage.restore_all(saved_hashes)

      PreviewData.set_modified_files(modified_files, saved_contents)
    end
  end
end

---チャットウィンドウを閉じる
function M.close()
  if M._current_buffer then
    M._current_buffer:close()
  end
end

---チャットウィンドウが開いているか
---@return boolean
function M.is_open()
  return M._current_buffer ~= nil and M._current_buffer:is_open()
end

---現在のバッファがチャットバッファかチェック
---@return boolean
function M.is_current_buffer_chat()
  local current_buf = vim.api.nvim_get_current_buf()

  -- アタッチ済みバッファをチェック
  if M._attached_buffers[current_buf] then
    return true
  end

  -- メインチャットバッファをチェック
  if M._current_buffer and M._current_buffer.buf == current_buf then
    return true
  end

  return false
end

---現在のチャットバッファインスタンスを取得
---@return Vibing.ChatBuffer?
function M.get_current()
  local current_buf = vim.api.nvim_get_current_buf()

  -- アタッチ済みバッファをチェック
  if M._attached_buffers[current_buf] then
    return M._attached_buffers[current_buf]
  end

  -- メインチャットバッファをチェック
  if M._current_buffer and M._current_buffer.buf == current_buf then
    return M._current_buffer
  end

  return nil
end

---既存バッファにアタッチ（:eで開いたファイル用）
---@param bufnr number バッファ番号
---@param file_path string ファイルパス
function M.attach_to_buffer(bufnr, file_path)
  if M._attached_buffers[bufnr] then
    return M._attached_buffers[bufnr]
  end

  local vibing = require("vibing")
  local config = vibing.get_config()

  local chat_buf = ChatBuffer:new(config.chat)
  chat_buf.buf = bufnr
  chat_buf.file_path = file_path

  -- フロントマターからsession_idを読み込み
  local frontmatter = chat_buf:parse_frontmatter()
  local sid = frontmatter.session_id
  if type(sid) == "string" and sid ~= "" and sid ~= "~" then
    chat_buf.session_id = sid
  end

  -- saved_hashesからsaved_contentsを復元
  if frontmatter.saved_hashes and type(frontmatter.saved_hashes) == "table" then
    local GitBlobStorage = require("vibing.infrastructure.storage.git_blob")
    local PreviewData = require("vibing.presentation.chat.modules.preview_data")

    local saved_contents = GitBlobStorage.restore_all(frontmatter.saved_hashes)

    if next(saved_contents) then
      -- modified_filesも復元（frontmatterのsaved_hashesのキーから）
      local modified_files = {}
      for path, _ in pairs(saved_contents) do
        table.insert(modified_files, path)
      end
      PreviewData.set_modified_files(modified_files, saved_contents)
    end
  end

  chat_buf:_setup_keymaps()

  M._attached_buffers[bufnr] = chat_buf
  return chat_buf
end

---アタッチ済みバッファをクリーンアップ
function M.cleanup_attached_buffers()
  for bufnr, _ in pairs(M._attached_buffers) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      M._attached_buffers[bufnr] = nil
    end
  end
end

return M
