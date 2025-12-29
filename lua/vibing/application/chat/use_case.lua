local Context = require("vibing.context")
local ChatBuffer = require("vibing.ui.chat_buffer")
local Formatter = require("vibing.context.formatter")
local notify = require("vibing.utils.notify")
local BufferIdentifier = require("vibing.utils.buffer_identifier")

---@class Vibing.ChatAction
local M = {}

---:VibingChatで作成されるメインチャットバッファ
---@type Vibing.ChatBuffer?
M.chat_buffer = nil

---:eで開いた.vibingファイルのアタッチ済みバッファ（バッファ番号 → ChatBuffer）
---@type table<number, Vibing.ChatBuffer>
M.attached_buffers = {}

---現在のバッファに対応するChatBufferを取得
---@return Vibing.ChatBuffer?
function M.get_current_chat_buffer()
  local current_buf = vim.api.nvim_get_current_buf()

  -- アタッチ済みバッファをチェック
  if M.attached_buffers[current_buf] then
    return M.attached_buffers[current_buf]
  end

  -- メインチャットバッファをチェック
  if M.chat_buffer and M.chat_buffer.buf == current_buf then
    return M.chat_buffer
  end

  return nil
end

---チャットを開く
---常に新しいチャットバッファを作成し、M.chat_bufferを上書き
---複数の独立した会話を同時に進行可能にする
---設定のchat.windowに基づいてウィンドウを表示
function M.open()
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- 常に新しいChatBufferインスタンスを作成
  local chat_buf = ChatBuffer:new(config.chat)
  chat_buf:open()

  -- 最新のチャットバッファとして追跡
  M.chat_buffer = chat_buf
end

---チャットを閉じる
---ウィンドウのみ閉じてバッファは保持（再度open()で再表示可能）
function M.close()
  if M.chat_buffer then
    M.chat_buffer:close()
  end
end

---チャットをトグル
---既存のM.chat_bufferが存在する場合はそれをトグル
---存在しない場合は新規作成（初回のみM.open()と同じ動作）
---この関数は既存の会話を保持して表示/非表示を切り替えるために使用
function M.toggle()
  if M.chat_buffer and M.chat_buffer:is_open() then
    M.close()
  else
    -- M.chat_bufferが存在しない場合のみ新規作成
    if not M.chat_buffer then
      M.open()
    else
      -- 既存のM.chat_bufferを再度開く
      M.chat_buffer:open()
    end
  end
end

---保存されたチャットファイルを開く
---:VibingOpenChatコマンドで呼び出される
---ファイルからコンテンツを読み込み、session_idを復元して会話を再開
---@param file_path string 開くチャットファイルの絶対パス
function M.open_file(file_path)
  local vibing = require("vibing")
  local config = vibing.get_config()

  if not M.chat_buffer then
    M.chat_buffer = ChatBuffer:new(config.chat)
  end

  if M.chat_buffer:load_from_file(file_path) then
    M.chat_buffer:_create_window()
    M.chat_buffer:_setup_keymaps()
    notify.info("Loaded chat: " .. file_path, "Chat")
  else
    notify.error("Failed to load: " .. file_path, "Chat")
  end
end

---既存バッファにアタッチ（通常の:eで開いたチャットファイル用）
---BufReadPost autocmdから呼び出され、通常のバッファをチャットバッファとして機能させる
---フロントマターからsession_idを読み込み、キーマップを設定
---@param buf number バッファ番号
---@param file_path string ファイルパス
function M.attach_to_buffer(buf, file_path)
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- 新しいChatBufferインスタンスを作成し、attached_buffersに登録
  -- M.chat_bufferは上書きしない（VibingChatで新規作成可能にするため）
  local chat_buf = ChatBuffer:new(config.chat)
  chat_buf.buf = buf
  chat_buf.file_path = file_path
  chat_buf.win = vim.api.nvim_get_current_win()

  -- filetypeをvibingに変更（mkdnなどの干渉を防ぐ）
  vim.bo[buf].filetype = "vibing"
  vim.bo[buf].syntax = "markdown"

  -- フロントマターからsession_idを取得
  local frontmatter = chat_buf:parse_frontmatter()
  -- session_idが有効な文字列の場合のみ設定（空文字列と~はnullとして扱う）
  local sid = frontmatter.session_id
  if type(sid) == "string" and sid ~= "" and sid ~= "~" then
    chat_buf.session_id = sid
  end

  -- キーマップを設定
  chat_buf:_setup_keymaps()

  -- attached_buffersに登録
  M.attached_buffers[buf] = chat_buf
end

---メッセージを送信
---チャットバッファから呼び出され、アダプターを介してClaudeにメッセージを送信
---コンテキスト統合、セッション継続、ストリーミング応答を処理
---@param chat_buffer Vibing.ChatBuffer 送信元のチャットバッファ
---@param message string ユーザーメッセージ（## Userセクションから抽出）
function M.send(chat_buffer, message)
  local vibing = require("vibing")
  local adapter = vibing.get_adapter()
  local config = vibing.get_config()

  if not adapter then
    notify.error("No adapter configured", "Chat")
    return
  end

  -- コンテキストを取得
  local contexts = Context.get_all(config.chat.auto_context)

  -- プロンプトにコンテキストを統合
  local formatted_prompt = Formatter.format_prompt(
    message,
    contexts,
    config.chat.context_position
  )

  -- 会話履歴を取得（SDK resume bug対策）
  local conversation = chat_buffer:extract_conversation()
  if #conversation == 0 then
    chat_buffer:update_filename_from_message(message)
  end

  -- 応答セクションを開始
  chat_buffer:start_response()

  -- frontmatterからmode/model/permissionsを取得してoptsに含める
  local frontmatter = chat_buffer:parse_frontmatter()

  -- Claude実行前に開いているバッファの内容を保存
  local saved_contents = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local file_path = vim.api.nvim_buf_get_name(buf)
      local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      if file_path ~= "" then
        -- Named buffer: use absolute path as key
        local normalized_path = vim.fn.fnamemodify(file_path, ":p")
        saved_contents[normalized_path] = content
      else
        -- Unnamed buffer: use [Buffer N] identifier as key
        local buffer_id = BufferIdentifier.create_identifier(buf)
        saved_contents[buffer_id] = content
      end
    end
  end

  -- StatusManager作成
  local StatusManager = require("vibing.status_manager")
  local status_mgr = StatusManager:new(config.status)

  -- 変更されたファイルを追跡
  local modified_files = {}
  local file_tools = { Edit = true, Write = true, nvim_set_buffer = true }

  local opts = {
    streaming = true,
    action_type = "chat",
    status_manager = status_mgr,
    mode = frontmatter.mode,
    model = frontmatter.model,
    permissions_allow = frontmatter.permissions_allow,
    permissions_deny = frontmatter.permissions_deny,
    permissions_ask = frontmatter.permissions_ask,
    permission_mode = frontmatter.permission_mode,
    on_tool_use = function(tool, file_path)
      if file_tools[tool] and file_path then
        -- 重複を避けて追加
        local already_exists = false
        for _, path in ipairs(modified_files) do
          if path == file_path then
            already_exists = true
            break
          end
        end
        if not already_exists then
          table.insert(modified_files, file_path)
        end
      end
    end,
  }

  -- セッションIDを opts に含める（新しいハンドルで使用）
  -- 新規チャット（session_id未設定）の場合は明示的にnilを設定して新しいセッションを開始
  -- _session_id_explicit フラグで明示的に設定されたことを示す（commit 8d89445 の修正を維持）
  if adapter:supports("session") then
    -- 古いセッションをクリーンアップ（完了済みのハンドルに紐づくセッション）
    adapter:cleanup_stale_sessions()

    local saved_session = chat_buffer:get_session_id()
    opts._session_id = saved_session
    opts._session_id_explicit = true  -- 明示的に設定されたことを示すフラグ
  end

  -- ストリーミング実行
  if adapter:supports("streaming") then
    local handle_id = adapter:stream(formatted_prompt, opts, function(chunk)
      vim.schedule(function()
        chat_buffer:append_chunk(chunk)
      end)
    end, function(response)
      vim.schedule(function()
        if response.error then
          status_mgr:set_error(response.error)
          chat_buffer:append_chunk("\n\n**Error:** " .. response.error)
        else
          status_mgr:set_done(modified_files)
        end

        -- 編集されたファイル一覧を表示
        if #modified_files > 0 then
          -- 変更されたファイルをリロード（inline機能と同様）
          local BufferReload = require("vibing.utils.buffer_reload")
          BufferReload.reload_files(modified_files)

          chat_buffer:append_chunk("\n\n### Modified Files\n\n")
          for _, file_path in ipairs(modified_files) do
            -- 相対パスに変換
            local relative_path = vim.fn.fnamemodify(file_path, ":.")
            chat_buffer:append_chunk(relative_path .. "\n")
          end
          -- プレビューUI用に保存（保存した内容も含める）
          chat_buffer:set_last_modified_files(modified_files, saved_contents)
        end

        -- セッションIDを同期（adapter → chat_buffer）
        -- handle_id を使って正しいセッションIDを取得
        if adapter:supports("session") and response._handle_id then
          local new_session = adapter:get_session_id(response._handle_id)
          if new_session and new_session ~= chat_buffer:get_session_id() then
            chat_buffer:update_session_id(new_session)
          end
          -- NOTE: cleanup_session() はここで呼ばない
          -- チャット継続時に同じセッションIDを使用できるようにするため
        end
        chat_buffer:add_user_section()
      end)
    end)
  else
    -- 非ストリーミング
    local response = adapter:execute(formatted_prompt, opts)

    if response.error then
      status_mgr:set_error(response.error)
      chat_buffer:append_chunk("**Error:** " .. response.error)
    else
      status_mgr:set_done(modified_files)
      chat_buffer:append_chunk(response.content)
    end

    -- 編集されたファイル一覧を表示
    if #modified_files > 0 then
      -- 変更されたファイルをリロード（inline機能と同様）
      local BufferReload = require("vibing.utils.buffer_reload")
      BufferReload.reload_files(modified_files)

      chat_buffer:append_chunk("\n\n### Modified Files\n\n")
      for _, file_path in ipairs(modified_files) do
        -- 相対パスに変換
        local relative_path = vim.fn.fnamemodify(file_path, ":.")
        chat_buffer:append_chunk(relative_path .. "\n")
      end
      -- プレビューUI用に保存（保存内容も一緒に渡す）
      chat_buffer:set_last_modified_files(modified_files, saved_contents)
    end

    -- セッションIDを同期（handle_id を使用）
    if adapter:supports("session") and response._handle_id then
      local new_session = adapter:get_session_id(response._handle_id)
      if new_session then
        chat_buffer:update_session_id(new_session)
      end
      -- NOTE: cleanup_session() はここで呼ばない
      -- チャット継続時に同じセッションIDを使用できるようにするため
    end
    chat_buffer:add_user_section()
  end
end

return M
