---@class Vibing.Application.ChatUseCase
---チャット機能のアプリケーション層Use Case
---ビジネスロジックのみを担当し、Presentation層に依存しない
local M = {}

local Context = require("vibing.application.context.manager")
local ChatSession = require("vibing.domain.chat.session")
local Formatter = require("vibing.infrastructure.context.formatter")
local notify = require("vibing.core.utils.notify")
local BufferIdentifier = require("vibing.core.utils.buffer_identifier")

---現在アクティブなセッション
---@type Vibing.ChatSession?
M._current_session = nil

---新しいチャットセッションを作成
---@return Vibing.ChatSession
function M.create_new()
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- 新しいセッションを作成
  local session = ChatSession:new({
    frontmatter = {
      ["vibing.nvim"] = true,
      created_at = os.date("%Y-%m-%dT%H:%M:%S"),
      mode = config.agent and config.agent.default_mode or "code",
      model = config.agent and config.agent.default_model or "sonnet",
      permission_mode = config.permissions and config.permissions.mode or "acceptEdits",
      permissions_allow = config.permissions and config.permissions.allow or {},
      permissions_deny = config.permissions and config.permissions.deny or {},
    },
  })

  -- ファイルパスを設定
  local save_location_type = config.chat.save_location_type or "project"
  local save_path
  if save_location_type == "project" then
    save_path = vim.fn.getcwd() .. "/.vibing/chat/"
  elseif save_location_type == "user" then
    save_path = vim.fn.stdpath("data") .. "/vibing/chats/"
  else
    save_path = config.chat.save_dir or (vim.fn.getcwd() .. "/.vibing/chat/")
  end
  if not save_path:match("/$") then
    save_path = save_path .. "/"
  end

  vim.fn.mkdir(save_path, "p")
  local filename = os.date("chat-%Y%m%d-%H%M%S.vibing")
  session:set_file_path(save_path .. filename)

  M._current_session = session
  return session
end

---既存のチャットファイルを開く
---@param file_path string ファイルパス
---@return Vibing.ChatSession?
function M.open_file(file_path)
  local session = ChatSession.load_from_file(file_path)
  if session then
    M._current_session = session
    return session
  end
  return nil
end

---現在のセッションを取得、存在しない場合は新規作成
---@return Vibing.ChatSession
function M.get_or_create_session()
  if M._current_session then
    return M._current_session
  end
  return M.create_new()
end

---メッセージ送信処理（ビジネスロジック）
---@param chat_buffer Vibing.ChatBuffer チャットバッファ（View層から渡される）
---@param message string ユーザーメッセージ
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
        local normalized_path = vim.fn.fnamemodify(file_path, ":p")
        saved_contents[normalized_path] = content
      else
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

  -- セッションIDを opts に含める
  if adapter:supports("session") then
    adapter:cleanup_stale_sessions()

    local saved_session = chat_buffer:get_session_id()
    opts._session_id = saved_session
    opts._session_id_explicit = true
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
          local BufferReload = require("vibing.core.utils.buffer_reload")
          BufferReload.reload_files(modified_files)

          chat_buffer:append_chunk("\n\n### Modified Files\n\n")
          for _, file_path in ipairs(modified_files) do
            local relative_path = vim.fn.fnamemodify(file_path, ":.")
            chat_buffer:append_chunk(relative_path .. "\n")
          end
          chat_buffer:set_last_modified_files(modified_files, saved_contents)
        end

        -- セッションIDを同期
        if adapter:supports("session") and response._handle_id then
          local new_session = adapter:get_session_id(response._handle_id)
          if new_session and new_session ~= chat_buffer:get_session_id() then
            chat_buffer:update_session_id(new_session)
          end
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
    chat_buffer:add_user_section()
  end
end

---既存バッファにアタッチ（:eで開いたファイル用）
---@param bufnr number バッファ番号
---@param file_path string ファイルパス
function M.attach_to_buffer(bufnr, file_path)
  local view = require("vibing.presentation.chat.view")
  view.attach_to_buffer(bufnr, file_path)
end

return M
