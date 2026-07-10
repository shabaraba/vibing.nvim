---@class Vibing.Application.SendMessageUseCase
---メッセージ送信ユースケース
local M = {}

-- bufnrをキーに、セッション開始時のスナップショットIDを保持
-- 並行セッション間でのmote差分混入を防ぐためのベースライン管理
local session_snapshots = {}

---バッファのセッションスナップショットをクリア（BufUnload時に呼ぶ）
---@param bufnr number
function M.cleanup_snapshots(bufnr)
  session_snapshots[bufnr] = nil
end

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
---@field get_handle_id fun(): string|nil handle_idを取得
---@field get_cwd fun(): string|nil worktreeのcwdを取得

---メッセージを送信
---@param adapter table アダプター
---@param callbacks Vibing.ChatCallbacks チャットバッファへの操作コールバック
---@param message string メッセージ
---@param config table 設定
function M.execute(adapter, callbacks, message, config)
  -- Per-chat adapter override from frontmatter "agent" field
  local original_adapter = adapter
  adapter = M._resolve_adapter(adapter, callbacks, config)

  -- per-chatアダプターが別インスタンスの場合、callbacksに登録してキャンセル経路を確保
  if adapter ~= original_adapter and callbacks.set_adapter then
    callbacks.set_adapter(adapter)
  end

  if not adapter then
    require("vibing.core.utils.notify").error("No adapter configured", "Chat")
    return
  end

  local bufnr = callbacks.get_bufnr()
  local session_cwd = callbacks.get_cwd and callbacks.get_cwd() or nil
  local frontmatter = callbacks.parse_frontmatter()
  -- mote_dirs (array) が優先。後方互換として mote_cwd (string) も読む
  local mote_dirs = frontmatter and frontmatter.mote_dirs
  if type(mote_dirs) == "string" then
    mote_dirs = { mote_dirs }
  end
  if (not mote_dirs or #mote_dirs == 0) and frontmatter and frontmatter.mote_cwd then
    mote_dirs = { frontmatter.mote_cwd }
  end
  local mote_configs = M._create_session_mote_configs(config, callbacks.get_session_id(), bufnr, session_cwd, mote_dirs)

  -- 実際のメッセージ送信処理（mote初期化後に呼び出される）
  local function do_send()
    local formatted_prompt = message

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

    -- レスポンス中にWrite/Editで変更されたファイルパスを追跡
    local modified_file_paths = {}

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
      chat_file_path = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or nil,
      on_tool_use = function(tool, file_path, _command)
        if (tool == "Write" or tool == "Edit" or tool == "NotebookEdit") and file_path then
          modified_file_paths[file_path] = true
        elseif tool == "FileChange" and file_path then
          -- Codex adapter reports comma-joined paths
          for path in file_path:gmatch("[^,]+") do
            modified_file_paths[vim.trim(path)] = true
          end
        end
      end,
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
      on_approval_required = function(tool, input, options, hook_request_id)
        -- permission.lua の vim.schedule 内から呼ばれるためすでにメインスレッド上
        -- 二重 vim.schedule を避けることで _pending_approval が add_user_section より確実に先に設定される
        callbacks.insert_approval_request(tool, input, options, hook_request_id)
        -- cancel は permission.lua 側で実行済み（hook-based / agent-wrapper 共通）
        -- add_user_section は on_done 経由で呼ばれる
      end,
    }

    if adapter:supports("session") then
      adapter:cleanup_stale_sessions()
      opts._session_id = callbacks.get_session_id()
      opts._session_id_explicit = true

      if frontmatter.forked_from then
        opts._is_fork = true
      end
    end

    if adapter:supports("streaming") then
      local handle_id = adapter:stream(formatted_prompt, opts, function(chunk)
        vim.schedule(function()
          callbacks.append_chunk(chunk)
        end)
      end, function(response)
        vim.schedule(function()
          M._handle_response(response, callbacks, adapter, config, mote_configs, modified_file_paths)
        end)
      end)
      -- handle_idをコールバックで設定（キャンセル用）
      if handle_id and callbacks.set_handle_id then
        callbacks.set_handle_id(handle_id)
      end
    else
      local response = adapter:execute(formatted_prompt, opts)
      M._handle_response(response, callbacks, adapter, config, mote_configs, modified_file_paths)
    end
  end

  -- mote統合が有効な場合は初期化とsnapshotを待ってから送信
  -- 無効な場合は即座に送信
  if mote_configs and #mote_configs > 0 then
    M._ensure_mote_initialized_and_snapshot(mote_configs, bufnr, function()
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
function M._handle_response(response, callbacks, adapter, config, mote_configs, modified_file_paths)
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

  if callbacks.clear_forked_from then
    callbacks.clear_forked_from()
  end

  -- mote統合: 有効なconfigが1つでもあればModified Files出力とpatch生成
  local MoteDiff = require("vibing.core.utils.mote_diff")

  -- セッション開始時のスナップショットIDをベースラインとして各configに設定
  local active_configs = {}
  local snapshots_by_ctx = session_snapshots[bufnr] or {}
  for _, mc in ipairs(mote_configs or {}) do
    if MoteDiff.is_initialized(mc.project, mc.context) then
      local cfg = vim.deepcopy(mc)
      cfg.baseline_snapshot_id = snapshots_by_ctx[mc.context]
      table.insert(active_configs, cfg)
    end
  end

  -- Write/Editで実際にファイルが変更された場合のみmote diffを実行
  local has_file_changes = next(modified_file_paths or {}) ~= nil

  if #active_configs > 0 and has_file_changes then
    -- 全configから変更ファイルを収集し、重複排除して出力
    local all_files = {}
    local seen_files = {}
    local patch_paths = {}
    local remaining = #active_configs
    local timestamp = os.date("%Y%m%d_%H%M%S")
    local diff_finalized = false
    local diff_timeout_timer = nil

    local function finalize()
      if diff_finalized then return end
      diff_finalized = true
      if diff_timeout_timer then
        vim.fn.timer_stop(diff_timeout_timer)
        diff_timeout_timer = nil
      end
      if #all_files > 0 then
        BufferReload.reload_files(all_files)
        local MAX_DISPLAY = 50
        local file_lines = {}
        for i = 1, math.min(#all_files, MAX_DISPLAY) do
          table.insert(file_lines, all_files[i])
        end
        if #all_files > MAX_DISPLAY then
          table.insert(file_lines, string.format("... (%d more)", #all_files - MAX_DISPLAY))
        end
        callbacks.append_chunk("\n\n### Modified Files\n\n" .. table.concat(file_lines, "\n") .. "\n")
      end
      for _, pp in ipairs(patch_paths) do
        callbacks.append_chunk("\n<!-- patch: " .. pp .. " -->\n")
      end
      vim.schedule(function()
        callbacks.add_user_section()
      end)
    end

    -- mote diffに時間がかかる場合でもUserセクションを即座に表示するタイムアウト
    diff_timeout_timer = vim.fn.timer_start(5000, vim.schedule_wrap(finalize))

    for _, mc in ipairs(active_configs) do
      MoteDiff.get_changed_files(mc, function(success, files, err)
        if success and files then
          for _, f in ipairs(files) do
            if not seen_files[f] then
              seen_files[f] = true
              table.insert(all_files, f)
            end
          end
        elseif not success then
          vim.notify("[vibing] Failed to get changed files: " .. (err or "Unknown error"), vim.log.levels.WARN)
        end

        if #(files or {}) > 0 then
          local context_dir = MoteDiff.build_context_dir_path(mc.project, mc.context)
          if context_dir then
            local patch_path = string.format("%s/patches/%s.patch", context_dir, timestamp)
            MoteDiff.generate_patch(mc, patch_path, function(patch_success, patch_error)
              if not patch_success then
                vim.notify("[vibing] Patch generation failed: " .. (patch_error or "Unknown error"), vim.log.levels.WARN)
              end
            end)
            table.insert(patch_paths, patch_path)
          end
        end

        remaining = remaining - 1
        if remaining == 0 then
          finalize()
        end
      end)
    end
  else
    callbacks.add_user_section()
  end

  -- NOTE: clear_handle_id() は呼ばない
  -- 次のsend_message()時にkillすることで、ゾンビプロセス対策になる
end

---セッション固有のmote設定を作成（単一dir用）
---@param config table 全体設定
---@param session_cwd string|nil worktreeのcwd
---@param mote_dir string|nil 追跡ディレクトリ（絶対パス）。nilの場合はworktree自動検出
---@return table|nil
function M._create_session_mote_config(config, session_cwd, mote_dir)
  if not config.diff or not config.diff.mote then
    return nil
  end

  local MoteDiff = require("vibing.core.utils.mote_diff")
  local mote_config = vim.deepcopy(config.diff.mote)

  mote_config.project = mote_config.project or MoteDiff.get_project_name()
  local context_prefix = mote_config.context_prefix or "vibing"

  if mote_dir then
    mote_config.context = MoteDiff.build_context_name_from_path(context_prefix, mote_dir)
    mote_config.cwd = mote_dir
  else
    mote_config.context = MoteDiff.build_context_name(context_prefix, session_cwd)
    if session_cwd then
      mote_config.cwd = session_cwd
    end
  end

  return mote_config
end

---複数のmote_dirsに対してmote設定の配列を作成
---@param config table 全体設定
---@param session_id string|nil セッションID（将来の拡張用）
---@param bufnr number|nil バッファ番号（将来の拡張用）
---@param session_cwd string|nil worktreeのcwd
---@param mote_dirs string[]|nil VibingMoteDirで指定された追跡ディレクトリ一覧
---@return table[] mote設定の配列（空の場合はempty table）
function M._create_session_mote_configs(config, session_id, bufnr, session_cwd, mote_dirs)
  if mote_dirs and #mote_dirs > 0 then
    local configs = {}
    for _, dir in ipairs(mote_dirs) do
      local cfg = M._create_session_mote_config(config, session_cwd, dir)
      if cfg then
        table.insert(configs, cfg)
      end
    end
    return configs
  end

  -- mote_dirs未指定: worktree自動検出（従来の動作）
  local cfg = M._create_session_mote_config(config, session_cwd, nil)
  return cfg and { cfg } or {}
end

-- Mote initialization timeout (10 seconds)
local MOTE_INIT_TIMEOUT_MS = 10000

---mote storageの初期化を確認し、スナップショットを作成（複数configs対応）
---全configの初期化+snapshot完了後に on_complete を呼ぶ
---@param mote_configs table[] セッション固有のmote設定配列
---@param bufnr number|nil バッファ番号（スナップショットID保存先キー）
---@param on_complete fun() 完了時のコールバック
function M._ensure_mote_initialized_and_snapshot(mote_configs, bufnr, on_complete)
  local MoteDiff = require("vibing.core.utils.mote_diff")
  if not MoteDiff.is_available() or #mote_configs == 0 then
    on_complete()
    return
  end

  local completed = false
  local timeout_timer = nil
  local remaining = #mote_configs

  local function complete_once()
    if completed then return end
    completed = true
    if timeout_timer then
      vim.fn.timer_stop(timeout_timer)
      timeout_timer = nil
    end
    on_complete()
  end

  local function on_one_done()
    remaining = remaining - 1
    if remaining == 0 then
      complete_once()
    end
  end

  timeout_timer = vim.fn.timer_start(MOTE_INIT_TIMEOUT_MS, function()
    if not completed then
      vim.notify("[vibing] mote initialization timeout - proceeding without mote", vim.log.levels.WARN)
      complete_once()
    end
  end)

  for _, mote_config in ipairs(mote_configs) do
    local mc = mote_config  -- ループ変数のキャプチャ

    local function create_snapshot()
      MoteDiff.create_snapshot(mc, "Before request", function(success, snapshot_id, err)
        if not success and err and not err:match("No changes to snapshot") then
          vim.notify("[vibing] Snapshot creation failed: " .. err, vim.log.levels.WARN)
        end
        if snapshot_id and bufnr then
          if not session_snapshots[bufnr] then
            session_snapshots[bufnr] = {}
          end
          session_snapshots[bufnr][mc.context] = snapshot_id
        end
        on_one_done()
      end)
    end

    if MoteDiff.is_initialized(mc.project, mc.context) then
      create_snapshot()
    else
      MoteDiff.initialize(mc, function(init_success, init_error)
        if completed then return end
        if not init_success then
          vim.notify("[vibing] mote initialization failed: " .. (init_error or "Unknown error"), vim.log.levels.WARN)
          on_one_done()
          return
        end
        create_snapshot()
      end)
    end
  end
end

---フロントマターのagentフィールドに基づいてアダプターを解決
---@param default_adapter table デフォルトアダプター（init.luaで初期化されたもの）
---@param callbacks Vibing.ChatCallbacks
---@param config table
---@return table adapter
function M._resolve_adapter(default_adapter, callbacks, config)
  local Modes = require("vibing.core.constants.modes")
  local frontmatter = callbacks.parse_frontmatter()
  local agent_type = frontmatter and frontmatter.agent

  if not agent_type then
    return default_adapter
  end

  if not Modes.is_valid_agent(agent_type) then
    vim.notify(
      string.format("[vibing] Invalid agent '%s' in frontmatter; using default adapter", tostring(agent_type)),
      vim.log.levels.WARN
    )
    return default_adapter
  end

  if default_adapter and default_adapter.name then
    local expected_name = agent_type == "codex" and "codex_cli" or "claude_cli"
    if default_adapter.name == expected_name then
      return default_adapter
    end
  end

  if agent_type == "codex" then
    local CodexCLI = require("vibing.infrastructure.adapter.codex_cli")
    return CodexCLI:new(config)
  else
    local ClaudeCLI = require("vibing.infrastructure.adapter.claude_cli")
    return ClaudeCLI:new(config)
  end
end

return M
