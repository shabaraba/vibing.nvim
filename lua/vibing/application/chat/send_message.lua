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
---@field set_handle_id fun(handle_id: string) handle_idを設定
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

  local bufnr = callbacks.get_bufnr()
  local session_cwd = callbacks.get_cwd and callbacks.get_cwd() or nil
  local mote_config = M._create_session_mote_config(config, callbacks.get_session_id(), bufnr, session_cwd)

  -- 実際のメッセージ送信処理（mote初期化後に呼び出される）
  local function do_send()
    local contexts = Context.get_all(config.chat.auto_context)
    local formatted_prompt = Formatter.format_prompt(message, contexts, config.chat.context_position)

    local conversation = callbacks.extract_conversation()
    if #conversation == 0 then
      callbacks.update_filename_from_message(message)
    end

    callbacks.start_response()

    -- Start gradient animation
    local buf = callbacks.get_bufnr()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      GradientAnimation.start(buf)
    end

    local frontmatter = callbacks.parse_frontmatter()

    -- Get language code: frontmatter > config
    local language_utils = require("vibing.core.utils.language")
    local lang_code = frontmatter.language
    if not lang_code then
      lang_code = language_utils.get_language_code(config.language, "chat")
    end

    -- Get cwd from frontmatter working_dir
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
      language = lang_code,
      cwd = session_cwd,
      on_insert_choices = function(questions)
        vim.schedule(function()
          callbacks.insert_choices(questions)
        end)
      end,
      on_session_corrupted = function(old_session_id)
        vim.schedule(function()
          callbacks.update_session_id(nil)
          -- Safely handle nil old_session_id
          local session_display = old_session_id and tostring(old_session_id):sub(1, 8) or "unknown"
          vim.notify(
            string.format(
              "[vibing.nvim] Previous session (%s) was corrupted. Starting fresh session.",
              session_display
            ),
            vim.log.levels.INFO
          )
        end)
      end,
      on_approval_required = function(tool, input, options)
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

    if adapter:supports("streaming") then
      local handle_id = adapter:stream(formatted_prompt, opts, function(chunk)
        vim.schedule(function()
          callbacks.append_chunk(chunk)
        end)
      end, function(response)
        vim.schedule(function()
          M._handle_response(response, callbacks, adapter, config, mote_config)
        end)
      end)
      -- handle_idをコールバックで設定（キャンセル用）
      if handle_id and callbacks.set_handle_id then
        callbacks.set_handle_id(handle_id)
      end
    else
      local response = adapter:execute(formatted_prompt, opts)
      M._handle_response(response, callbacks, adapter, config, mote_config)
    end
  end

  -- mote統合が有効な場合は初期化とsnapshotを待ってから送信
  -- 無効な場合は即座に送信
  if mote_config then
    M._ensure_mote_initialized_and_snapshot(mote_config, config.diff, function()
      vim.schedule(do_send)
    end)
  else
    do_send()
  end
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

  -- Lua側タイムアウトによるセッション破損検出
  if response._session_corrupted then
    callbacks.update_session_id(nil)
    callbacks.append_chunk("\n\n**Session Timeout:** The previous session could not be resumed.")
    callbacks.append_chunk("\n*Session has been reset. Your next message will start a new session.*")
    callbacks.add_user_section()
    -- NOTE: clear_handle_id() は呼ばない（次のsend_message()でkillする）
    return
  end

  if response.error then
    callbacks.append_chunk("\n\n**Error:** " .. response.error)

    if is_session_error(tostring(response.error)) and callbacks.get_session_id() then
      callbacks.update_session_id(nil)
      callbacks.append_chunk("\n\n*Session has been reset. Your next message will start a new session.*")
      vim.notify("[vibing] Session error detected - session has been automatically reset", vim.log.levels.WARN)
    end
  end

  local new_session_id = nil
  if adapter:supports("session") and response._handle_id then
    new_session_id = adapter:get_session_id(response._handle_id)
    if new_session_id and new_session_id ~= callbacks.get_session_id() then
      callbacks.update_session_id(new_session_id)
    end
  end

  -- mote統合: session_idが確定したら一時ディレクトリをリネーム
  local MoteDiff = require("vibing.core.utils.mote_diff")
  if mote_config and new_session_id then
    local is_temp_id = mote_config.mote_session_id and (
      mote_config.mote_session_id:match("^_buffer_") or
      mote_config.mote_session_id:match("^_temp_")
    )
    if is_temp_id then
      local base_storage_dir = config.diff and config.diff.mote and config.diff.mote.storage_dir or ".vibing/mote"
      local new_storage_dir, rename_success = MoteDiff.rename_storage_dir(
        mote_config.storage_dir,
        new_session_id,
        base_storage_dir,
        mote_config.cwd  -- Pass cwd for worktree detection
      )
      -- Convert new_storage_dir to absolute path
      local Git = require("vibing.core.utils.git")
      local git_root = Git.get_root()
      local new_storage_dir_abs = git_root and (git_root .. "/" .. new_storage_dir) or new_storage_dir

      -- mote_configを更新（リネーム成功/失敗に関わらず新しいパスを使用）
      if rename_success then
        mote_config.storage_dir = new_storage_dir_abs
        mote_config.mote_session_id = new_session_id
      else
        -- リネーム失敗時も新しいパスを記録（patch生成時に使用）
        mote_config.storage_dir = new_storage_dir_abs
        mote_config.mote_session_id = new_session_id
        vim.notify(
          string.format(
            "[vibing] Failed to rename mote storage directory.\n" ..
            "Old: %s\nNew: %s\n" ..
            "Continuing with new path...",
            vim.fn.fnamemodify(mote_config.storage_dir, ":."),
            vim.fn.fnamemodify(new_storage_dir, ":.")
          ),
          vim.log.levels.WARN
        )
      end
    end
  end

  -- mote統合: config.diff.toolが適切に設定され、mote_configが存在し、初期化済みの場合にModified Files出力とpatch生成
  local using_mote = mote_config ~= nil
    and (config.diff.tool == "mote" or config.diff.tool == "auto")
    and MoteDiff.is_initialized(nil, mote_config.storage_dir)

  if using_mote then
    MoteDiff.get_changed_files(mote_config, function(success, files, error)
      if success and files and #files > 0 then
        -- Patch生成（mote storage配下に保存）
        -- Use session-specific storage_dir directly from mote_config to support custom storage directories
        local storage_base = vim.fn.fnamemodify(mote_config.storage_dir, ":p"):gsub("/$", "")
        local timestamp = os.date("%Y%m%d_%H%M%S")
        local patch_path = string.format("%s/patches/%s.patch", storage_base, timestamp)

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

  -- NOTE: clear_handle_id() は呼ばない
  -- 次のsend_message()時にkillすることで、ゾンビプロセス対策になる
end

---セッション固有のmote設定を作成
---@param config table 全体設定
---@param session_id string|nil セッションID
---@param bufnr number|nil バッファ番号（session_idがない場合のfallback用）
---@param session_cwd string|nil worktreeのcwd（worktreeで作業する場合のみ、worktree判定用）
---@return table|nil セッション固有のmote設定（mote未設定の場合nil）
function M._create_session_mote_config(config, session_id, bufnr, session_cwd)
  if not config.diff or not config.diff.mote then
    return nil
  end

  -- session_idがない場合はbufnrベースのIDを使用
  local mote_session_id = session_id
  if not mote_session_id then
    if bufnr then
      mote_session_id = "_buffer_" .. tostring(bufnr)
    else
      -- bufnrもない場合はタイムスタンプベースのID
      mote_session_id = "_temp_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999))
    end
  end

  local MoteDiff = require("vibing.core.utils.mote_diff")
  local mote_config = vim.deepcopy(config.diff.mote)
  -- mote v0.2.0: worktree分離対応（cwdからworktreeを判定して適切なパスを生成）
  local relative_storage_dir = MoteDiff.build_session_storage_dir(mote_config.storage_dir, mote_session_id, session_cwd)

  -- プロジェクトルートからの絶対パスに変換
  local Git = require("vibing.core.utils.git")
  local git_root = Git.get_root()
  if git_root then
    mote_config.storage_dir = git_root .. "/" .. relative_storage_dir
  else
    mote_config.storage_dir = relative_storage_dir
  end

  mote_config.mote_session_id = mote_session_id -- patch_path生成用に保存

  -- worktreeで作業する場合はcwdを設定
  -- moteコマンドはこのcwdで実行され、worktree内のファイルのみを追跡する
  if session_cwd then
    mote_config.cwd = session_cwd
  end

  return mote_config
end

-- Mote initialization timeout (10 seconds)
local MOTE_INIT_TIMEOUT_MS = 10000

---mote storageの初期化を確認し、スナップショットを作成
---タイムアウト処理とエラーハンドリングを含む
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

  -- Track completion to prevent double-calling on_complete
  local completed = false
  local timeout_timer = nil

  local function complete_once()
    if completed then return end
    completed = true
    if timeout_timer then
      vim.fn.timer_stop(timeout_timer)
      timeout_timer = nil
    end
    on_complete()
  end

  -- Set up timeout to prevent infinite waiting
  timeout_timer = vim.fn.timer_start(MOTE_INIT_TIMEOUT_MS, function()
    if not completed then
      vim.notify("[vibing] mote initialization timeout - proceeding without mote", vim.log.levels.WARN)
      complete_once()
    end
  end)

  local function create_snapshot()
    MoteDiff.create_snapshot(mote_config, "Before request", function(success, _, error)
      if not success and error and not error:match("No changes to snapshot") then
        vim.notify("[vibing] Snapshot creation failed: " .. error, vim.log.levels.WARN)
      end
      complete_once()
    end)
  end

  if MoteDiff.is_initialized(nil, mote_config.storage_dir) then
    create_snapshot()
    return
  end

  MoteDiff.initialize(mote_config, function(init_success, init_error)
    if completed then return end -- Already timed out
    if not init_success then
      vim.notify("[vibing] mote initialization failed: " .. (init_error or "Unknown error"), vim.log.levels.WARN)
      complete_once()
      return
    end
    create_snapshot()
  end)
end

return M
