---@class Vibing.Presentation.ChatView
---チャット機能のView層ファサード
---ChatBufferインスタンスの管理とセッションとの紐付けを担当
local M = {}

local ChatBuffer = require("vibing.presentation.chat.buffer")
local notify = require("vibing.core.utils.notify")

---現在アクティブなチャットバッファ（:VibingChatで作成）
---@type Vibing.ChatBuffer?
M._current_buffer = nil

---:eで開いたチャットファイルのアタッチ済みバッファ（バッファ番号 → ChatBuffer）
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
  chat_buf.session = session  -- セッション全体を保持（後方互換性のため）
  if session.file_path then
    chat_buf.file_path = session.file_path
  end
  -- session_idが有効な値の場合のみ設定（nilや空文字は設定しない）
  if session.session_id and session.session_id ~= "" then
    chat_buf.session_id = session.session_id
  end
  -- NOTE: cwdはfrontmatterのworking_dirから算出されるため、ここでの転送は不要

  -- 位置指定が指定されている場合は一時的にオーバーライド
  if position then
    chat_buf.config.window.position = position
  end

  chat_buf:open()

  -- セッションの内容をバッファに書き込む
  if session.file_path and vim.fn.filereadable(session.file_path) == 1 then
    local content = vim.fn.readfile(session.file_path)
    vim.api.nvim_buf_set_lines(chat_buf.buf, 0, -1, false, content)
    -- NOTE: Diff display now uses patch files stored in .vibing/patches/<session_id>/
    -- The gd keymap reads patch files directly via PatchFinder and PatchViewer
  end

  -- ファイル内容読み込み後にチャットバッファ設定を適用（wrap設定、補完、autocmdなど）
  -- これによりftpluginによる上書きを防ぐ
  M._apply_chat_buffer_settings(chat_buf.buf)
end

---チャットウィンドウを閉じる
function M.close()
  if M._current_buffer then
    M._current_buffer:close()
  end
end

-- NOTE: Patch-based diff system
-- Modified Filesセクションの差分表示はpatchファイル方式に移行済み
-- - `.vibing/patches/<session_id>/<timestamp>.patch`に保存
-- - `gd`キーマップでPatchViewerを使用して表示
-- - SessionStorage/GitBlobStorage/PreviewDataは不要になった

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

---Get current chat buffer instance (for current buffer)
---@return Vibing.ChatBuffer?
function M.get_current()
  local current_buf = vim.api.nvim_get_current_buf()

  -- Check attached buffers
  if M._attached_buffers[current_buf] then
    return M._attached_buffers[current_buf]
  end

  -- Check main chat buffer
  if M._current_buffer and M._current_buffer.buf == current_buf then
    return M._current_buffer
  end

  return nil
end

---Get ChatBuffer instance for a specific buffer number (public API)
---@param bufnr number Buffer number
---@return Vibing.ChatBuffer?
function M.get_chat_buffer(bufnr)
  -- Check attached buffers
  if M._attached_buffers[bufnr] then
    return M._attached_buffers[bufnr]
  end

  -- Check main chat buffer
  if M._current_buffer and M._current_buffer.buf == bufnr then
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

  -- NOTE: Diff display uses patch files in .vibing/patches/<session_id>/
  -- The gd keymap reads patch files directly via PatchFinder and PatchViewer

  chat_buf:_setup_keymaps()

  -- vibing.nvimチャットファイル用のバッファ設定を適用
  M._apply_chat_buffer_settings(bufnr)

  M._attached_buffers[bufnr] = chat_buf
  return chat_buf
end

---チャットバッファ用の設定を適用
---ftplugin/vibing.luaから移動した設定
---@param bufnr number バッファ番号
function M._apply_chat_buffer_settings(bufnr)
  -- バッファローカル設定
  vim.bo[bufnr].syntax = "markdown"
  vim.bo[bufnr].commentstring = "<!-- %s -->"
  vim.bo[bufnr].textwidth = 0
  vim.bo[bufnr].formatoptions = "tcqj"

  -- 補完設定
  local ok_completion, completion = pcall(require, "vibing.application.completion")
  if ok_completion and completion.setup_buffer then
    pcall(completion.setup_buffer, bufnr)
  elseif ok_completion then
    pcall(function()
      vim.bo[bufnr].omnifunc = "v:lua.require('vibing.application.completion').omnifunc"
      vim.bo[bufnr].completeopt = "menu,menuone,noselect"
    end)
  end

  -- nvim-cmp設定
  local has_cmp, cmp = pcall(require, "cmp")
  if has_cmp then
    local ok_completion_module, completion_module = pcall(require, "vibing.application.completion")
    if ok_completion_module then
      completion_module.setup()
    end

    local global_config_cmp = cmp.get_config()
    local existing_sources = global_config_cmp.sources or {}

    local merged_sources = {
      { name = "vibing", priority = 1000 },
    }
    for _, source in ipairs(existing_sources) do
      if source.name ~= "vibing" then
        table.insert(merged_sources, source)
      end
    end

    cmp.setup.buffer({
      sources = merged_sources,
    })
  end

  -- wrap設定の適用
  local ok_ui, ui_utils = pcall(require, "vibing.core.utils.ui")
  if ok_ui then
    -- 初回適用（force=trueで強制適用、新規作成直後のバッファはまだフロントマターがないため）
    pcall(ui_utils.apply_wrap_config, 0, bufnr, true)

    -- Mark buffer as chat buffer immediately (cache for performance)
    vim.b[bufnr].vibing_is_chat_buffer = true

    -- FileTypeでwrap設定を再適用（ftplugin（markdown.vim等）による上書きを防ぐ）
    -- WinEnterはグローバルイベント（init.lua）で処理するため、ここでは不要
    local group = vim.api.nvim_create_augroup("vibing_wrap_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      buffer = bufnr,
      callback = function()
        pcall(ui_utils.apply_wrap_config, 0, bufnr, true)
      end,
      desc = "Apply vibing wrap settings after filetype detection",
    })

    -- BufWritePost: フロントマターが変更された可能性があるためキャッシュをクリア
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      buffer = bufnr,
      callback = function()
        vim.b[bufnr].vibing_is_chat_buffer = nil
      end,
      desc = "Clear chat buffer cache after write",
    })
  end

  -- BufUnloadでのクリーンアップ
  local cleanup_group = vim.api.nvim_create_augroup("vibing_cleanup_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = cleanup_group,
    buffer = bufnr,
    callback = function()
      local chat_buffer = M._attached_buffers[bufnr] or (M._current_buffer and M._current_buffer.buf == bufnr and M._current_buffer)
      if chat_buffer and chat_buffer._current_handle_id then
        local ok_vibing, vibing_module = pcall(require, "vibing")
        if ok_vibing then
          local adapter = vibing_module.get_adapter()
          if adapter then
            adapter:cancel(chat_buffer._current_handle_id)
          end
        end
      end
      -- アタッチ済みバッファからクリーンアップ
      M._attached_buffers[bufnr] = nil
    end,
    desc = "Cancel running Agent SDK process on buffer unload",
  })

  -- ウィンドウローカル設定（現在のウィンドウに適用）
  local winnr = vim.fn.bufwinnr(bufnr)
  if winnr > 0 then
    vim.api.nvim_win_call(vim.fn.win_getid(winnr), function()
      vim.wo.conceallevel = 2
      vim.wo.spell = false
    end)
  end
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
