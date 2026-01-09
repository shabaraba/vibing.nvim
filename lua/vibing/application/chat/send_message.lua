---@class Vibing.Application.SendMessageUseCase
---メッセージ送信ユースケース
-- Test comment for verifying patch path format fix
local M = {}

local Context = require("vibing.application.context.manager")
local Formatter = require("vibing.infrastructure.context.formatter")
local BufferReload = require("vibing.core.utils.buffer_reload")
local BufferIdentifier = require("vibing.core.utils.buffer_identifier")
local GradientAnimation = require("vibing.ui.gradient_animation")

---@class Vibing.ChatCallbacks
---@field extract_conversation fun(): table 会話履歴を抽出
---@field update_filename_from_message fun(message: string) メッセージからファイル名を更新
---@field start_response fun() レスポンス開始
---@field parse_frontmatter fun(): table Frontmatterを解析
---@field append_chunk fun(chunk: string) チャンクを追加
---@field set_last_modified_files fun(files: string[], saved_contents: table) 変更ファイル一覧を設定
---@field get_session_id fun(): string|nil セッションIDを取得
---@field update_session_id fun(session_id: string) セッションIDを更新
---@field add_user_section fun() ユーザーセクションを追加
---@field get_bufnr fun(): number バッファ番号を取得
---@field insert_choices fun(questions: table) AskUserQuestion選択肢を挿入
---@field clear_handle_id fun() handle_idをクリア
---@field update_saved_hashes fun(saved_hashes: table<string, string>) saved_hashesを更新

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
  local saved_contents = M._save_buffer_contents()

  local modified_files = {}
  local file_tools = { Edit = true, Write = true, nvim_set_buffer = true }
  local pre_saved_patch_filename = nil  -- git操作前に保存されたpatchファイル名

  -- Get language code: frontmatter > config
  local language_utils = require("vibing.core.utils.language")
  local lang_code = frontmatter.language
  if not lang_code then
    lang_code = language_utils.get_language_code(config.language, "chat")
  end

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
    on_tool_use = function(tool, file_path, command)
      if file_tools[tool] and file_path then
        local normalized_path = vim.fn.fnamemodify(file_path, ":p")
        if not saved_contents[normalized_path] then
          if vim.fn.filereadable(normalized_path) == 1 then
            local ok, content = pcall(vim.fn.readfile, normalized_path)
            if ok then
              saved_contents[normalized_path] = content
            end
          else
            saved_contents[normalized_path] = {}
          end
        end
        if not vim.tbl_contains(modified_files, file_path) then
          table.insert(modified_files, file_path)
        end
      end

      -- Bashでgit commit/add/revert等を検知したらpatchを即座に保存
      if tool == "Bash" and command and #modified_files > 0 then
        local is_git_destructive = command:match("^git%s+commit")
          or command:match("^git%s+add")
          or command:match("^git%s+revert")
          or command:match("^git%s+reset")
          or command:match("^git%s+checkout")
          or command:match("^git%s+stash")
        if is_git_destructive and not pre_saved_patch_filename then
          local PatchStorage = require("vibing.infrastructure.storage.patch_storage")
          local session_id = callbacks.get_session_id()
          if session_id then
            pre_saved_patch_filename = PatchStorage.save_from_contents(session_id, modified_files, saved_contents)
          end
        end
      end
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
        M._handle_response(response, callbacks, modified_files, saved_contents, adapter, pre_saved_patch_filename)
      end)
    end)
  else
    local response = adapter:execute(formatted_prompt, opts)
    M._handle_response(response, callbacks, modified_files, saved_contents, adapter, pre_saved_patch_filename)
  end

  return handle_id
end

---バッファの内容を保存
---@return table<string, string[]>
function M._save_buffer_contents()
  local saved = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local file_path = vim.api.nvim_buf_get_name(buf)
      local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      if file_path ~= "" then
        saved[vim.fn.fnamemodify(file_path, ":p")] = content
      else
        saved[BufferIdentifier.create_identifier(buf)] = content
      end
    end
  end
  return saved
end

---レスポンスを処理
function M._handle_response(response, callbacks, modified_files, saved_contents, adapter, pre_saved_patch_filename)
  -- Stop gradient animation
  local bufnr = callbacks.get_bufnr()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    GradientAnimation.stop(bufnr)
  end

  if response.error then
    callbacks.append_chunk("\n\n**Error:** " .. response.error)
  end

  if #modified_files > 0 then
    BufferReload.reload_files(modified_files)

    -- patchファイルを保存（git操作前に保存済みの場合はそれを使用）
    local PatchStorage = require("vibing.infrastructure.storage.patch_storage")
    local session_id = callbacks.get_session_id()
    local patch_filename = pre_saved_patch_filename

    if not patch_filename and session_id then
      patch_filename = PatchStorage.save(session_id, modified_files)
    end

    -- Modified Filesセクションを出力
    callbacks.append_chunk("\n\n### Modified Files\n\n")
    for _, file_path in ipairs(modified_files) do
      callbacks.append_chunk(vim.fn.fnamemodify(file_path, ":.") .. "\n")
    end

    -- patchファイル名をコメントとして追加
    if patch_filename then
      callbacks.append_chunk("\n<!-- patch: " .. patch_filename .. " -->\n")
    end

    callbacks.set_last_modified_files(modified_files, saved_contents)
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
