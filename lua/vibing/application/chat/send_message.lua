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
---@field insert_approval_request fun(tool: string, input: table, options: table) ツール承認要求UIを挿入
---@field get_session_allow fun(): table セッションレベルの許可リストを取得
---@field get_session_deny fun(): table セッションレベルの拒否リストを取得
---@field clear_handle_id fun() handle_idをクリア
---@field get_cwd fun(): string|nil worktreeのcwdを取得

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

  local mote_config = M._create_session_mote_config(config, callbacks.get_session_id())
  local mote_ready = false

  -- mote統合が有効な場合は初期化とsnapshotを待つ
  if mote_config then
    M._ensure_mote_initialized_and_snapshot(mote_config, config.diff, function()
      mote_ready = true
    end)
    -- mote初期化を待つ（最大5秒）
    local timeout = 50 -- 50 * 100ms = 5秒
    while not mote_ready and timeout > 0 do
      vim.wait(100)
      timeout = timeout - 1
    end
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

  -- Get language code: frontmatter > config
  local language_utils = require("vibing.core.utils.language")
  local lang_code = frontmatter.language
  if not lang_code then
    lang_code = language_utils.get_language_code(config.language, "chat")
  end

  -- Get cwd from chat buffer (if set by VibingChatWorktree)
  local session_cwd = callbacks.get_cwd and callbacks.get_cwd() or nil

  -- Get session-level permissions from buffer
  local session_allow = callbacks.get_session_allow()
  local session_deny = callbacks.get_session_deny()

  local opts = {
    streaming = true,
    action_type = "chat",
    mode = frontmatter.mode,
    model = frontmatter.model,
    permissions_allow = frontmatter.permissions_allow,
    permissions_deny = frontmatter.permissions_deny,
    permissions_ask = frontmatter.permissions_ask,
    permissions_session_allow = session_allow,
    permissions_session_deny = session_deny,
    permission_mode = frontmatter.permission_mode,
    language = lang_code,  -- Pass language code to adapter
    cwd = session_cwd,  -- Pass worktree cwd if set (from memory, not frontmatter)
    on_insert_choices = function(questions)
      -- Forward insert_choices event to chat buffer
      vim.schedule(function()
        callbacks.insert_choices(questions)
      end)
    end,
    on_session_corrupted = function(old_session_id)
      -- Clear corrupted session_id from frontmatter
      vim.schedule(function()
        callbacks.update_session_id(nil)
        vim.notify(
          string.format(
            "[vibing.nvim] Previous session (%s) was corrupted. Starting fresh session.",
            old_session_id:sub(1, 8) -- Show only first 8 chars for brevity
          ),
          vim.log.levels.INFO -- Changed from WARN to INFO (less alarming)
        )
      end)
    end,
    on_approval_required = function(tool, input, options)
      -- Forward approval_required event to chat buffer
      vim.schedule(function()
        callbacks.insert_approval_request(tool, input, options)
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
        M._handle_response(response, callbacks, adapter, config, mote_config)
      end)
    end)
  else
    local response = adapter:execute(formatted_prompt, opts)
    M._handle_response(response, callbacks, adapter, config, mote_config)
  end

  return handle_id
end

---セッションエラーかどうかを判定
---@param error_msg string エラーメッセージ
---@return boolean
local function is_session_error(error_msg)
  local lower_msg = error_msg:lower()
  return lower_msg:match("session") or lower_msg:match("invalid") or lower_msg:match("expired")
end

---レスポンスを処理
function M._handle_response(response, callbacks, adapter, config, mote_config)
  -- Stop gradient animation
  local bufnr = callbacks.get_bufnr()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    GradientAnimation.stop(bufnr)
  end

  if response.error then
    callbacks.append_chunk("\n\n**Error:** " .. response.error)

    if is_session_error(tostring(response.error)) and callbacks.get_session_id() then
      callbacks.update_session_id(nil)
      callbacks.append_chunk("\n\n*Session has been reset. Your next message will start a new session.*")
      vim.notify("[vibing] Session error detected - session has been automatically reset", vim.log.levels.WARN)
    end
  end

  if adapter:supports("session") and response._handle_id then
    local new_session = adapter:get_session_id(response._handle_id)
    if new_session and new_session ~= callbacks.get_session_id() then
      callbacks.update_session_id(new_session)
    end
  end

  -- mote統合: mote_configが存在し、初期化済みの場合にModified Files出力とpatch生成
  local using_mote = mote_config ~= nil
    and require("vibing.core.utils.mote_diff").is_initialized(nil, mote_config.storage_dir)

  if using_mote then
    local MoteDiff = require("vibing.core.utils.mote_diff")
    MoteDiff.get_changed_files(mote_config, function(success, files, error)
      if success and files and #files > 0 then
        -- Patch生成（mote storage配下に保存）
        local session_id = callbacks.get_session_id() or "unknown"
        local timestamp = os.date("%Y%m%d_%H%M%S")
        local patch_path = string.format(".vibing/mote/%s/patches/%s.patch", session_id, timestamp)

        MoteDiff.generate_patch(mote_config, patch_path, function(patch_success, patch_error)
          if not patch_success then
            vim.notify("[vibing] Patch generation failed: " .. (patch_error or "Unknown error"), vim.log.levels.WARN)
          end
        end)

        -- Modified Files出力
        BufferReload.reload_files(files)

        callbacks.append_chunk("\n\n### Modified Files\n\n")
        for _, file_path in ipairs(files) do
          callbacks.append_chunk(file_path .. "\n")
        end

        -- Patch marker (before User section)
        callbacks.append_chunk("\n<!-- patch: " .. patch_path .. " -->\n")
      elseif not success then
        vim.notify("[vibing] Failed to get changed files: " .. (error or "Unknown error"), vim.log.levels.WARN)
      end

      -- Userセクション追加（Modified Files + patch marker出力後）
      vim.schedule(function()
        callbacks.add_user_section()
      end)
    end)
  else
    -- Modified Filesが無い場合もUserセクション追加
    callbacks.add_user_section()
  end

  callbacks.clear_handle_id()
end

---セッション固有のmote設定を作成
---@param config table 全体設定
---@param session_id string|nil セッションID
---@return table|nil セッション固有のmote設定（mote未設定またはsession_idがnilの場合nil）
function M._create_session_mote_config(config, session_id)
  if not config.diff or not config.diff.mote then
    return nil
  end

  if not session_id then
    -- session_idが無い場合はエラー（mote統合にはsession_idが必須）
    return nil
  end

  local MoteDiff = require("vibing.core.utils.mote_diff")
  local mote_config = vim.deepcopy(config.diff.mote)
  mote_config.storage_dir = MoteDiff.build_session_storage_dir(mote_config.storage_dir, session_id)

  return mote_config
end

---mote storageの初期化を確認し、スナップショットを作成
---@param mote_config table セッション固有のmote設定
---@param diff_config table diff設定
---@param on_complete fun() 完了時のコールバック
function M._ensure_mote_initialized_and_snapshot(mote_config, diff_config, on_complete)
  if diff_config.tool ~= "mote" and diff_config.tool ~= "auto" then
    on_complete()
    return
  end

  local MoteDiff = require("vibing.core.utils.mote_diff")
  if not MoteDiff.is_available() then
    on_complete()
    return
  end

  local function create_snapshot()
    MoteDiff.create_snapshot(mote_config, "Before request", function(success, _, error)
      if not success and error and not error:match("No changes to snapshot") then
        vim.notify("[vibing] Snapshot creation failed: " .. error, vim.log.levels.WARN)
      end
      on_complete()
    end)
  end

  if MoteDiff.is_initialized(nil, mote_config.storage_dir) then
    create_snapshot()
    return
  end

  MoteDiff.initialize(mote_config, function(init_success, init_error)
    if not init_success then
      vim.notify("[vibing] mote initialization failed: " .. (init_error or "Unknown error"), vim.log.levels.WARN)
      on_complete()
      return
    end
    create_snapshot()
  end)
end

return M
