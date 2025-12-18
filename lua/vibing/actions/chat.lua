local Context = require("vibing.context")
local ChatBuffer = require("vibing.ui.chat_buffer")
local Formatter = require("vibing.context.formatter")
local notify = require("vibing.utils.notify")

---@class Vibing.ChatAction
local M = {}

---現在アクティブなチャットバッファインスタンス
---:VibingChatや:VibingOpenChatで作成される
---@type Vibing.ChatBuffer?
M.chat_buffer = nil

---チャットを開く
---既存のチャットバッファがない場合は新規作成
---設定のchat.windowに基づいてウィンドウを表示
function M.open()
  local vibing = require("vibing")
  local config = vibing.get_config()

  if not M.chat_buffer then
    M.chat_buffer = ChatBuffer:new(config.chat)
  end

  M.chat_buffer:open()
end

---チャットを閉じる
---ウィンドウのみ閉じてバッファは保持（再度open()で再表示可能）
function M.close()
  if M.chat_buffer then
    M.chat_buffer:close()
  end
end

---チャットをトグル
---開いている場合は閉じ、閉じている場合は開く
function M.toggle()
  if M.chat_buffer and M.chat_buffer:is_open() then
    M.close()
  else
    M.open()
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

  -- 新しいChatBufferインスタンスを作成し、既存バッファをアタッチ
  M.chat_buffer = ChatBuffer:new(config.chat)
  M.chat_buffer.buf = buf
  M.chat_buffer.file_path = file_path
  M.chat_buffer.win = vim.api.nvim_get_current_win()

  -- filetypeをvibingに変更（mkdnなどの干渉を防ぐ）
  vim.bo[buf].filetype = "vibing"
  vim.bo[buf].syntax = "markdown"

  -- フロントマターからsession_idを取得
  local frontmatter = M.chat_buffer:parse_frontmatter()
  if frontmatter.session_id and frontmatter.session_id ~= "" then
    M.chat_buffer.session_id = frontmatter.session_id
  end

  -- キーマップを設定
  M.chat_buffer:_setup_keymaps()

  notify.info("Chat session attached", "Chat")
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

  -- セッションIDを同期（chat_buffer → adapter）
  if adapter:supports("session") then
    local saved_session = chat_buffer:get_session_id()
    if saved_session then
      adapter:set_session_id(saved_session)
    end
  end

  -- 最初のメッセージの場合、ファイル名を更新
  local conversation = chat_buffer:extract_conversation()
  if #conversation == 0 then
    chat_buffer:update_filename_from_message(message)
  end

  -- 応答セクションを開始
  chat_buffer:start_response()

  -- ストリーミング実行
  if adapter:supports("streaming") then
    adapter:stream(formatted_prompt, {
      streaming = true,
    }, function(chunk)
      vim.schedule(function()
        chat_buffer:append_chunk(chunk)
      end)
    end, function(response)
      vim.schedule(function()
        if response.error then
          chat_buffer:append_chunk("\n\n**Error:** " .. response.error)
        end
        -- セッションIDを同期（adapter → chat_buffer）
        if adapter:supports("session") then
          local new_session = adapter:get_session_id()
          if new_session and new_session ~= chat_buffer:get_session_id() then
            chat_buffer:update_session_id(new_session)
          end
        end
        chat_buffer:add_user_section()
      end)
    end)
  else
    -- 非ストリーミング
    local response = adapter:execute(formatted_prompt, {})

    if response.error then
      chat_buffer:append_chunk("**Error:** " .. response.error)
    else
      chat_buffer:append_chunk(response.content)
    end
    -- セッションIDを同期
    if adapter:supports("session") then
      local new_session = adapter:get_session_id()
      if new_session then
        chat_buffer:update_session_id(new_session)
      end
    end
    chat_buffer:add_user_section()
  end
end

return M
