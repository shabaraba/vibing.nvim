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
---@param position? string 位置指定（core/constants/chat.lua の POSITIONS）
---@param opts? {background?: boolean} backgroundはM._current_bufferを更新しない
---@return Vibing.ChatBuffer chat_buf 作成したチャットバッファ
function M.render(session, position, opts)
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- 毎回新規バッファを作成（既存バッファを再利用しない）
  local chat_buf = ChatBuffer:new(config.chat)

  -- M._current_buffer は「ユーザーが最後に開いたチャット」を指すシングルトンで、
  -- :VibingCancel / :VibingToggleChat がカーソルがチャット外にあるときの
  -- フォールバックに使う。nvim_chat_createのワーカーはユーザーが開いたものではないので
  -- ここを奪ってはいけない。奪うと:VibingCancelがユーザーの実行中リクエストではなくワーカーを
  -- 止め、backのワーカーにはウィンドウが無いのでis_open()がfalseになり:VibingToggleChatが
  -- 開いているチャットをトグルせず新しいチャットを作ってしまう。
  -- 検索は_attached_buffers側で足りる（get_chat_buffer）ので、ワーカーが迷子になることはない
  if not (opts and opts.background) then
    M._current_buffer = chat_buf
  end

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

  -- 位置指定が指定されている場合はこのバッファに限ってオーバーライドする。
  -- ChatBuffer:new はグローバル設定テーブルへの参照をそのまま持つので、`window`テーブルまで
  -- 差し替えないと `:VibingChat back` 1回でユーザーの既定位置が永久にbackになる。
  -- tbl_deep_extendでは足りない: 空テーブルをベースにすると衝突が起きず、ネストした値は
  -- 参照のまま代入されるので `config.window` は同じテーブルのままになる（実測でConfig.defaults
  -- まで書き換わった）。nvim_chat_createはワーカーを常にbackで作るため、この漏れは致命的になる
  if position then
    chat_buf.config = vim.tbl_extend("force", {}, chat_buf.config, {
      window = vim.tbl_extend("force", {}, chat_buf.config.window, { position = position }),
    })
  end

  chat_buf:open()

  -- 複数チャット同時実行時も認識できるよう、bufnrキーでも追跡する
  -- （M._current_buffer は直近にrenderされたチャットしか指さないシングルトンのため）
  M._attached_buffers[chat_buf.buf] = chat_buf

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

  return chat_buf
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
  return M.get_current() ~= nil
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

  -- Self-heal: the buffer is a chat file (by path or frontmatter) but was never
  -- attached — e.g. the detection autocmd did not fire in time, or a cache went
  -- stale. Attach it on demand so commands work regardless of autocmd timing,
  -- instead of failing with "Not in a vibing chat buffer".
  local file_path = vim.api.nvim_buf_get_name(current_buf)
  if file_path and file_path ~= "" then
    local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
    if Frontmatter.is_vibing_chat_buffer(current_buf) then
      local ok, chat_buf = pcall(M.attach_to_buffer, current_buf, file_path)
      if ok and chat_buf then
        return chat_buf
      end
    end
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

  -- 補完設定（cmpソースのバッファスコープ管理も含め、completion.setup_buffer側の責務）
  local ok_completion, completion = pcall(require, "vibing.application.completion")
  if ok_completion and completion.setup_buffer then
    pcall(completion.setup_buffer, bufnr)
  elseif ok_completion then
    pcall(function()
      vim.bo[bufnr].omnifunc = "v:lua.require('vibing.application.completion').omnifunc"
      vim.bo[bufnr].completeopt = "menu,menuone,noselect"
    end)
  end

  -- wrap設定の適用
  local ok_ui, ui_utils = pcall(require, "vibing.core.utils.ui")
  if ok_ui then
    -- win=0（カレントウィンドウ）をそのまま渡すと、非同期アタッチ時にbufnrと
    -- 無関係なウィンドウのwrap設定を書き換えてしまうため、bufnrを表示している
    -- 実際のウィンドウを解決してから適用する（表示中のウィンドウがなければ何もしない）
    local function apply_wrap_for_bufnr()
      local winnr = vim.fn.bufwinnr(bufnr)
      if winnr > 0 then
        pcall(ui_utils.apply_wrap_config, vim.fn.win_getid(winnr), bufnr, true)
      end
    end

    -- 初回適用（force=trueで強制適用、新規作成直後のバッファはまだフロントマターがないため）
    apply_wrap_for_bufnr()

    -- Mark buffer as chat buffer immediately (cache for performance)
    vim.b[bufnr].vibing_is_chat_buffer = true

    -- FileTypeでwrap設定を再適用（ftplugin（markdown.vim等）による上書きを防ぐ）
    -- WinEnterはグローバルイベント（init.lua）で処理するため、ここでは不要
    local group = vim.api.nvim_create_augroup("vibing_wrap_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      buffer = bufnr,
      callback = function()
        apply_wrap_for_bufnr()
        -- Re-apply completion settings to prevent markdown ftplugin from overwriting omnifunc
        local ok_c, completion = pcall(require, "vibing.application.completion")
        if ok_c and completion.setup_buffer then
          pcall(completion.setup_buffer, bufnr)
        end
      end,
      desc = "Apply vibing wrap and completion settings after filetype detection",
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
        local adapter = chat_buffer:_get_active_adapter()
        if adapter then
          adapter:cancel(chat_buffer._current_handle_id)
        end
      end
      -- アタッチ済みバッファからクリーンアップ
      M._attached_buffers[bufnr] = nil
    end,
    desc = "Cancel running CLI process on buffer unload",
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

---生きているチャットバッファを列挙する
---
---`_attached_buffers` は `render` と `attach_to_buffer` の両方が埋めるので、`back` で作られた
---窓なしのワーカーも入る。`_current_buffer` はそのうちの1つを指すシングルトンにすぎないので、
---「いま何本走っているか」を数えるにはこちらしかない（`application/chat/concurrency`）
---@return table<number, Vibing.ChatBuffer>
function M.list_chat_buffers()
  local buffers = {}
  for bufnr, chat_buf in pairs(M._attached_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      buffers[bufnr] = chat_buf
    end
  end
  return buffers
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
