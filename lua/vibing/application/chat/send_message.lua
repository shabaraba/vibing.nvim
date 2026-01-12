---@class Vibing.Application.SendMessageUseCase
---メッセージ送信ユースケース
local M = {}

local Context = require("vibing.application.context.manager")
local Formatter = require("vibing.infrastructure.context.formatter")
local BufferReload = require("vibing.core.utils.buffer_reload")
local GradientAnimation = require("vibing.ui.gradient_animation")

---@class Vibing.ChatCallbacks
---@field extract_conversation fun(): table 会話履歴を抽出
---@field update_filename_from_message fun(message: string) メッセージからファイル名を更新
---@field start_response fun() レスポンス開始
---@field parse_frontmatter fun(): table Frontmatterを解析
---@field append_chunk fun(chunk: string) チャンクを追加
---@field get_session_id fun(): string|nil セッションIDを取得
---@field update_session_id fun(session_id: string) セッションIDを更新
---@field add_user_section fun() ユーザーセクションを追加
---@field get_bufnr fun(): number バッファ番号を取得
---@field insert_choices fun(questions: table) AskUserQuestion選択肢を挿入
---@field clear_handle_id fun() handle_idをクリア

---メッセージを送信
---@param adapter table アダプター
---@param callbacks Vibing.ChatCallbacks チャットバッファへの操作コールバック
---@param message string メッセージ
---@param config table 設定
function M.execute(adapter, callbacks, message, config)
  if not adapter then
    require("vibing.core.utils.notify").error("No adapter configured", "Chat")
    return
  end

  local contexts = Context.get_all(config.chat.auto_context)
  local formatted_prompt = Formatter.format_prompt(message, contexts, config.chat.context_position)

  local conversation = callbacks.extract_conversation()
  if #conversation == 0 then
    callbacks.update_filename_from_message(message)
  end

  callbacks.start_response()

  -- Start gradient animation
  local bufnr = callbacks.get_bufnr()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    GradientAnimation.start(bufnr)
  end

  local frontmatter = callbacks.parse_frontmatter()

  local patch_filename = nil

  -- Get language code: frontmatter > config
  local language_utils = require("vibing.core.utils.language")
  local lang_code = frontmatter.language
  if not lang_code then
    lang_code = language_utils.get_language_code(config.language, "chat")
  end

  -- Get cwd from current session (if set by VibingChatWorktree)
  local use_case = require("vibing.application.chat.use_case")
  local session_cwd = use_case._current_session and use_case._current_session:get_cwd()

  local opts = {
    streaming = true,
    action_type = "chat",
    mode = frontmatter.mode,
    model = frontmatter.model,
    permissions_allow = frontmatter.permissions_allow,
    permissions_deny = frontmatter.permissions_deny,
    permissions_ask = frontmatter.permissions_ask,
    permission_mode = frontmatter.permission_mode,
    language = lang_code,  -- Pass language code to adapter
    cwd = session_cwd,  -- Pass worktree cwd if set (from memory, not frontmatter)
    on_patch_saved = function(filename)
      patch_filename = filename
    end,
    on_insert_choices = function(questions)
      -- Forward insert_choices event to chat buffer
      vim.schedule(function()
        callbacks.insert_choices(questions)
      end)
    end,
  }

  if adapter:supports("session") then
    adapter:cleanup_stale_sessions()
    opts._session_id = callbacks.get_session_id()
    opts._session_id_explicit = true
  end

  local handle_id = nil
  if adapter:supports("streaming") then
    handle_id = adapter:stream(formatted_prompt, opts, function(chunk)
      vim.schedule(function()
        callbacks.append_chunk(chunk)
      end)
    end, function(response)
      vim.schedule(function()
        M._handle_response(response, callbacks, adapter, patch_filename)
      end)
    end)
  else
    local response = adapter:execute(formatted_prompt, opts)
    M._handle_response(response, callbacks, adapter, patch_filename)
  end

  return handle_id
end

---レスポンスを処理
function M._handle_response(response, callbacks, adapter, patch_filename)
  -- Stop gradient animation
  local bufnr = callbacks.get_bufnr()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    GradientAnimation.stop(bufnr)
  end

  if response.error then
    callbacks.append_chunk("\n\n**Error:** " .. response.error)
  end

  if patch_filename then
    local PatchParser = require("vibing.infrastructure.storage.patch_parser")
    local session_id = callbacks.get_session_id()
    local modified_files = PatchParser.extract_file_list(session_id, patch_filename)

    if #modified_files > 0 then
      BufferReload.reload_files(modified_files)

      callbacks.append_chunk("\n\n### Modified Files\n\n")
      for _, file_path in ipairs(modified_files) do
        callbacks.append_chunk(vim.fn.fnamemodify(file_path, ":.") .. "\n")
      end

      callbacks.append_chunk("\n<!-- patch: " .. patch_filename .. " -->\n")
    end
  end

  if adapter:supports("session") and response._handle_id then
    local new_session = adapter:get_session_id(response._handle_id)
    if new_session and new_session ~= callbacks.get_session_id() then
      callbacks.update_session_id(new_session)
    end
  end

  -- リクエスト完了時にhandle_idをクリア
  callbacks.clear_handle_id()

  callbacks.add_user_section()
end

return M
