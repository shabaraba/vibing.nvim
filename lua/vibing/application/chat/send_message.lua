---@class Vibing.Application.SendMessageUseCase
---メッセージ送信ユースケース
local M = {}

local BufferReload = require("vibing.core.utils.buffer_reload")
local GradientAnimation = require("vibing.ui.gradient_animation")
local ActiveStreamRegistry = require("vibing.infrastructure.adapter.modules.active_stream_registry")
local Fs = require("vibing.core.utils.fs")

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
---@field set_pending_user_text fun(text: string) 次のユーザーセクションに差し込む本文を保存
---@field insert_approval_request fun(tool: string, input: table, options: table) ツール承認要求UIを挿入
---@field get_session_allow fun(): table セッションレベルの許可リストを取得
---@field get_session_deny fun(): table セッションレベルの拒否リストを取得
---@field clear_handle_id fun() handle_idをクリア
---@field set_handle_id fun(handle_id: string) handle_idを設定
---@field get_handle_id fun(): string|nil handle_idを取得
---@field clear_sending fun() 送信中フラグを解除
---@field get_cwd fun(): string|nil worktreeのcwdを取得

---綴り間違いの警告済み集合。executeは1メッセージごとに走るので、これがないと同じ誤字の
---チャットで送信のたびに同じ警告が出続ける
---@type table<string, boolean>
local warned_modes = {}

---frontmatterの`mode`を検証する（`mode`の意味は core/constants/modes.lua を参照）
---@param mode any frontmatterのmode値
---@return string|nil mode 有効な場合はそのまま、無効な場合はnil
function M._validate_frontmatter_mode(mode)
  if mode == nil then
    return nil
  end

  local Modes = require("vibing.core.constants.modes")
  local valid = Modes.coerce_agent_mode(mode)
  if valid then
    return valid
  end

  -- Key on the type for non-strings: tostring() of a table is its address, which differs on
  -- every re-parse and would defeat the dedupe.
  local shown = type(mode) == "string" and mode or type(mode)
  if not warned_modes[shown] then
    warned_modes[shown] = true
    local valid_list = table.concat(Modes.AGENT_MODES, ", ")
    vim.notify(
      string.format("[vibing] Invalid mode '%s' in frontmatter; expected one of: %s", shown, valid_list),
      vim.log.levels.WARN
    )
  end
  return nil
end

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
    if callbacks.clear_sending then
      callbacks.clear_sending()
    end
    return
  end

  local bufnr = callbacks.get_bufnr()
  local frontmatter = callbacks.parse_frontmatter()

  -- A subagent chat shares its parent's session_id for good, so two buffers can now be pointed at
  -- one session. Two `claude --resume <same id>` processes append to the same transcript file, so
  -- refuse rather than corrupt it. Bail before start_response(), leaving the user's unsent
  -- `## User` message untouched so they can just resend.
  local session_id = callbacks.get_session_id and callbacks.get_session_id() or nil
  local conflict = ActiveStreamRegistry.find_other_active_for_session(session_id, bufnr)
  if conflict then
    require("vibing.core.utils.notify").error(
      string.format(
        "Buffer %s is using this same session right now — wait for it to finish.",
        tostring(conflict.chat_bufnr or "?")
      ),
      "Chat"
    )
    if callbacks.clear_sending then
      callbacks.clear_sending()
    end
    return
  end

  M._warn_removed_frontmatter(frontmatter)

  local formatted_prompt = message
  -- system promptにも同じ指示を入れているが、こちらはターンごとのメッセージなので
  -- プロンプトキャッシュの前方一致を壊さない。効かなかったときの保険として重ねておく
  local bound_agent = frontmatter and frontmatter.subagent_id
  if bound_agent then
    formatted_prompt = string.format("[Continuing subagent %s] %s", bound_agent, message)
  end

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

  -- start_response() がバッファに書いた後の状態で読み直す
  frontmatter = callbacks.parse_frontmatter()

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

  -- このチャットに指示を出したチャット。frontmatter が持つのはパスで、それが唯一
  -- セッションを越えて意味を保つ形なので、モデルに渡すのもパスを一次にする（#641）。
  -- bufnr は「いまの解決結果」として併記されるだけで、相手が開かれていなければ落ちる。
  -- 落ちても行は消えない — パスなら `nvim_chat_send_message` が開き直せる。
  --
  -- 通知が無効なら解決自体を行わない。ワーカーがオーケストレーターに話しかけられても
  -- 相手を起こす経路が無いので、プロンプトのトークンを払う理由がない。
  local orchestrators = nil
  local chat_notifications = config.agent and config.agent.chat_notifications
  if chat_notifications and chat_notifications.enabled then
    local ok, resolved =
      pcall(require("vibing.application.chat.chat_locator").resolve_all, frontmatter.orchestrated_by)
    if ok and #resolved > 0 then
      orchestrators = resolved
    end
  end

  local opts = {
    streaming = true,
    action_type = "chat",
    chat_bufnr = vim.api.nvim_buf_is_valid(bufnr) and bufnr or nil,
    orchestrators = orchestrators,
    mode = M._validate_frontmatter_mode(frontmatter.mode),
    model = frontmatter.model,
    effort = frontmatter.effort,
    permissions_allow = frontmatter.permissions_allow,
    permissions_deny = frontmatter.permissions_deny,
    permissions_ask = frontmatter.permissions_ask,
    permissions_session_allow = session_allow,
    permissions_session_deny = session_deny,
    permission_mode = frontmatter.permission_mode,
    language = lang_code,
    cwd = session_cwd,
    -- ツリースナップショット差分の帰属判定に使う。アダプタはこれをそのまま
    -- ActiveStreamRegistry に載せるだけで、git を呼ばない（`stream()` は同期I/Oを
    -- 増やさない）。
    --
    -- ここは `rev-parse --show-toplevel` 1回ぶんメインループを止める。architecture.md の
    -- 「Startup Cost」が同期I/Oに神経質なのに対して意図的に許容している箇所で、根拠は
    -- 呼ばれる回数のほう: git_snapshot 側でcwd単位にキャッシュされるので、1つのcwdにつき
    -- 最初の送信の1回だけで、以降はゼロ。setup() と違ってNeovim起動時には走らない
    _worktree_root = require("vibing.core.utils.git_snapshot").worktree_root(session_cwd),
    on_tool_use = function(tool, file_path, _command)
      if (tool == "Write" or tool == "Edit" or tool == "MultiEdit" or tool == "NotebookEdit") and file_path then
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

    -- forkは新しいsession_idへ分岐させるが、subagentチャットは分岐させてはいけない。
    -- subagentのtranscriptは親のsession_idのディレクトリにあり、--fork-sessionを付けると
    -- SendMessageが "No transcript found for agent ID" で失敗する（実CLIで確認済み）
    if frontmatter.subagent_id then
      opts._subagent_id = frontmatter.subagent_id
    elseif frontmatter.forked_from then
      opts._is_fork = true
    end
  end

  if adapter:supports("streaming") then
    local handle_id = adapter:stream(formatted_prompt, opts, function(chunk, chunk_handle_id)
      vim.schedule(function()
        callbacks.append_chunk(chunk, chunk_handle_id)
      end)
    end, function(response)
      vim.schedule(function()
        M._handle_response(response, callbacks, adapter, config, modified_file_paths, message)
      end)
    end)
    -- handle_idをコールバックで設定（キャンセル用）
    if handle_id and callbacks.set_handle_id then
      callbacks.set_handle_id(handle_id)
    end
  else
    local response = adapter:execute(formatted_prompt, opts)
    M._handle_response(response, callbacks, adapter, config, modified_file_paths, message)
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
---@param response table アダプターからのレスポンス
---@param callbacks Vibing.ChatCallbacks
---@param adapter table アダプター
---@param config table 設定
---@param modified_file_paths table<string, boolean> ツールイベントで検知した変更ファイル
---@param message string|nil 送信したユーザーメッセージ（リミットで弾かれた場合の再予約に使う）
function M._handle_response(response, callbacks, adapter, config, modified_file_paths, message)
  -- キャンセル済みの古いリクエストが遅れて完了した場合、現在アクティブなハンドルIDと
  -- 一致しないレスポンスは無視する（新しいリクエストの結果を上書きさせない）
  local incoming_handle_id = response._handle_id
  local RequestDiff = require("vibing.core.utils.request_diff")
  if incoming_handle_id and callbacks.get_handle_id then
    local current_handle_id = callbacks.get_handle_id()
    if current_handle_id and incoming_handle_id ~= current_handle_id then
      -- このリクエストは破棄されるので、両経路のベースラインも破棄する
      -- （どちらが使われるかはここまで来ないと決まらない）
      RequestDiff.clear(incoming_handle_id)
      require("vibing.core.utils.git_snapshot").clear(incoming_handle_id)
      return
    end
  end

  if callbacks.clear_sending then
    callbacks.clear_sending()
  end

  -- Stop gradient animation
  local bufnr = callbacks.get_bufnr()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    GradientAnimation.stop(bufnr)
  end

  -- Lua側タイムアウトによるセッション破損検出
  if response._session_corrupted then
    -- このターンの差分は出さずに抜けるので、両経路のベースラインもここで捨てる
    -- （どちらも「レスポンス処理の最後に必ずclearする」契約になっている）
    RequestDiff.clear(incoming_handle_id or (callbacks.get_handle_id and callbacks.get_handle_id()))
    require("vibing.core.utils.git_snapshot").clear(
      incoming_handle_id or (callbacks.get_handle_id and callbacks.get_handle_id())
    )
    callbacks.update_session_id(nil)
    callbacks.append_chunk("\n\n**Session Timeout:** The previous session could not be resumed.")
    callbacks.append_chunk("\n*Session has been reset. Your next message will start a new session.*")
    callbacks.add_user_section()
    -- NOTE: clear_handle_id() は呼ばない（次のsend_message()でkillする）
    return
  end

  -- 使用量リミットで弾かれた場合の扱い:
  --   1. プロジェクト単位のリセット時刻を記録し、次の送信を事前に予約へ回せるようにする
  --   2. 弾かれたターンの本文（何も出力せず弾かれた場合）か継続文言（途中まで進んでいた場合）を
  --      未送信Userセクションとして書き戻し、リセット後に送る予約を張る
  --   3. 予約に回せなかった場合だけ、従来の auto_resume（固定プロンプト）にフォールバックする
  -- リミット以外で正常終了したときはリトライ budget とリセット時刻の記録をクリアする。
  local AutoResume = require("vibing.application.chat.auto_resume")
  local LimitState = require("vibing.infrastructure.storage.limit_state")
  local chat_file_path = (bufnr and vim.api.nvim_buf_is_valid(bufnr)) and vim.api.nvim_buf_get_name(bufnr) or nil
  local chat_dir = chat_file_path and vim.fn.fnamemodify(chat_file_path, ":h") or nil
  -- 記録も解除もバックエンド単位。誰がリミットに当たったか（誰のリクエストが通ったか）は
  -- 実際に走ったアダプターそのものが答えで、ターン中に書き換わりうるfrontmatterではない。
  local agent = require("vibing.infrastructure.adapter.factory").agent_id(adapter)

  if response._rate_limit_info then
    pcall(LimitState.record, response._rate_limit_info, chat_dir, agent)
    local rescheduled = false
    local ok, result = pcall(
      M._reschedule_rejected_message,
      callbacks,
      chat_file_path,
      response._rate_limit_info,
      message,
      config,
      M._turn_progressed(response, modified_file_paths)
    )
    if ok then
      rescheduled = result
    end
    if not rescheduled then
      pcall(AutoResume.on_rate_limited, chat_file_path, response._rate_limit_info)
    end
  elseif not response.error then
    pcall(AutoResume.on_success, chat_file_path)
    pcall(LimitState.clear, chat_dir, agent)
  else
    -- リミット以外のエラーで終わったターンも、未送信Userセクションは消費済み。予約
    -- （scheduled）を残すと、その後そこに入った別のテキスト（書きかけの続きや承認UIの
    -- 選択肢）をタイマーが送ってしまうので破棄する。auto_resume側のリトライbudgetは
    -- リミットを観測したときにしか動かさないので、ここでは触らない。
    pcall(AutoResume.discard_scheduled, chat_file_path)
  end

  if response.error and not response._cancelled then
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

  local GitSnapshot = require("vibing.core.utils.git_snapshot")

  local handle_id_for_diff = incoming_handle_id or (callbacks.get_handle_id and callbacks.get_handle_id())

  -- 経路の選択:
  --   1. PreToolUseでツリースナップショットのベースラインが取れていて、
  --   2. そのworktreeで他のターンと重なっていない
  -- なら git snapshot（Bash由来の変更も拾える）。どちらか欠ければ request_diff に落ちる。
  --
  -- 2つ目の条件が要るのは、ツリーが共有状態だからで、同じworktreeで並行して走っている
  -- 別チャットのBash変更をこのターンの成果として書いてしまうため。取りこぼす方がまだ正確。
  --
  -- 重なりの判定は2つ必要で、片方だけでは足りない:
  --   - `had_overlap` は、ベースラインを取った時点で開いていた他リクエストのウィンドウを
  --     記録したもの。ここでレジストリを見るだけだと、先に終わった側しか相手を見つけられず、
  --     後に終わった側（相手の変更を実際に取り込んでしまう側）が素通りする
  --   - レジストリ照会は、ベースラインを取れなかった（スナップショット失敗など）ために
  --     git_snapshot からは見えないストリームを拾う保険
  local snapshot_root = GitSnapshot.get_root(handle_id_for_diff)
  local overlapping = snapshot_root
    and (
      GitSnapshot.had_overlap(handle_id_for_diff)
      or ActiveStreamRegistry.find_other_active_for_worktree(snapshot_root, handle_id_for_diff) ~= nil
    )
  local use_snapshot = snapshot_root ~= nil and not overlapping

  -- ツールイベントが1つも無くてもスナップショットは差分を持ちうる（Bashで書き換えた場合）。
  -- ベースラインは「変更しうるツール」が動いたときにしか取られないので、読み取りだけの
  -- ターンではここも空振りしない。
  local has_file_changes = next(modified_file_paths or {}) ~= nil

  -- フォールバックのバックアップは、スナップショット経路が **実際に差分を出せてから** 捨てる。
  -- 先に捨ててしまうと、2回目のスナップショットやdiff呼び出しが失敗した（権限・ディスク・
  -- 途中でworktreeが消えた等）ときに退避先が無く、そのターンの変更が何の通知もなく消える。
  -- それはこの置き換えが無くそうとしている失敗そのものなので、順序を逆にはできない。
  local handled = false
  if use_snapshot then
    handled = M._finalize_snapshot_diff(callbacks, handle_id_for_diff, modified_file_paths)
    if handled then
      RequestDiff.clear(handle_id_for_diff)
    end
  end

  if not handled then
    -- ここのclearは、スナップショット経路を通らなかった場合（git管理外・重なり検出）のための
    -- もの。上のfinalizeがfalseを返して落ちてきた場合は既にclear済みだが、clearは冪等
    GitSnapshot.clear(handle_id_for_diff)

    if has_file_changes then
      -- フォールバック: PreToolUseフックで退避した変更前内容からpatchを生成。
      -- 外部プロセスを使わず、触ったファイル数分のvim.diff()だけで完結する。
      M._finalize_request_diff(callbacks, handle_id_for_diff, modified_file_paths)
    else
      -- スナップショットを試したのに取れず、しかもツールイベントも1つも無かった場合は、
      -- 退避先が両方とも空になる。Bashだけで完結したターンではこれが起こりうる。そのときは
      -- 「変更なし」と見分けがつかない — Bash由来の変更が黙って消えるという、この仕組みが
      -- 無くそうとしている失敗そのものになる。頻度は低いが、黙るわけにはいかないので通知する。
      if use_snapshot then
        vim.notify(
          "[vibing] Could not read this turn's changes: the working tree snapshot failed, "
            .. "and no tool reported a file. Check `git status` — any changes are still on disk.",
          vim.log.levels.WARN
        )
      end
      RequestDiff.clear(handle_id_for_diff)
      callbacks.add_user_section()
    end
  end

  -- NOTE: clear_handle_id() は呼ばない
  -- 次のsend_message()時にkillすることで、ゾンビプロセス対策になる
end

---弾かれたターンが途中まで進んでいたか
---
---進んでいたなら、そのユーザーメッセージも部分的な作業もセッションのtranscriptに残っている。
---同じ本文を送り直すとモデルは同じ依頼を2回受け取り、済んだ作業をやり直しかねないので、
---呼び出し側はここがtrueのときだけ継続文言に切り替える。
---
---判定は「モデルが何か出力したか」だけを見る。content にはテキストdeltaとツール結果の表示が
---入る（cli_event_processor）ので、非空ならAPI呼び出しは通っている。空ならリミットは
---ターンの入口で弾いたということなので、本文を送り直す従来の挙動が正しい。
---@param response table
---@param modified_file_paths table<string, boolean>|nil
---@return boolean
function M._turn_progressed(response, modified_file_paths)
  if next(modified_file_paths or {}) ~= nil then
    return true
  end
  local content = response and response.content
  return type(content) == "string" and vim.trim(content) ~= ""
end

---リミットで弾かれたメッセージを、リセット後に再送する予約に切り替える
---
---本文はバッファの未送信Userセクションが唯一の置き場所なので、ここではJSONに複製せず
---set_pending_user_textで次のセクションに差し込むよう予約するだけにする。
---セクション生成は_handle_response内の3経路から行われ、いずれもvim.schedule越しなので、
---直接書き込むとどれが走るかで競合する。
---@param callbacks Vibing.ChatCallbacks
---@param chat_file_path string|nil
---@param info Vibing.RateLimitInfo
---@param message string|nil 弾かれたユーザーメッセージ
---@param config table
---@param progressed boolean|nil 弾かれたターンが途中まで進んでいたか（M._turn_progressed）
---@return boolean rescheduled 予約に切り替えられたか
function M._reschedule_rejected_message(callbacks, chat_file_path, info, message, config, progressed)
  local opts = (config.agent and config.agent.scheduled_requests) or {}
  if not opts.enabled then
    return false
  end
  if not chat_file_path or chat_file_path == "" or not message or vim.trim(message) == "" then
    return false
  end
  if not callbacks.set_pending_user_text then
    return false
  end

  -- リセット時刻が分からない場合は予約時刻を決められない。固定プロンプトを投げ直す
  -- auto_resume のフォールバック待ちにする方が、当てずっぽうの時刻で再送するより無害。
  if not info.resets_at then
    return false
  end

  local PendingResume = require("vibing.infrastructure.storage.pending_resume")
  local existing = PendingResume.get(chat_file_path)

  -- `message` is whatever the turn sent, and an auto_resume continuation is a turn too: fire()
  -- sends `opts.prompt` ("Continue from where you left off.") through the ordinary send path.
  -- Converting that to a scheduled request would write a sentence the user never typed into the
  -- buffer as their own message, and swap auto_resume's max_retries budget (default 1) for
  -- scheduled_requests' (default 3). fire() marks the entry in_flight before sending, so an
  -- in-flight auto_resume entry is exactly that case; hand it back to on_rate_limited, which
  -- owns that budget. A scheduled entry in flight is the documented re-schedule loop and stays.
  if existing and (existing.kind or "auto_resume") == "auto_resume" and existing.state == "in_flight" then
    return false
  end

  local retry_count = (existing and existing.retry_count or 0) + 1

  local AutoResume = require("vibing.application.chat.auto_resume")
  local grace = (config.agent and config.agent.auto_resume_on_limit and config.agent.auto_resume_on_limit.grace_sec)
    or 10

  local ok, reason = AutoResume.schedule_request(chat_file_path, info.resets_at + grace, {
    limit_type = info.limit_type,
    retry_count = retry_count,
    max_retries = opts.max_retries or 3,
  })
  if not ok then
    vim.notify(
      string.format(
        "[vibing] Not re-scheduling %s: %s",
        vim.fn.fnamemodify(chat_file_path, ":t"),
        tostring(reason)
      ),
      vim.log.levels.WARN
    )
    return false
  end

  callbacks.set_pending_user_text(progressed and M._continuation_prompt(config) or message)
  return true
end

---途中まで進んだターンを再開させる一言
---
---auto_resume_on_limit.prompt を流用する。意味が「リミット後にセッションを続けるための一言」で
---同じであり、既定値の置き場所を1つに保つため。auto_resume が無効でも値そのものは読める。
---@param config table
---@return string
function M._continuation_prompt(config)
  local prompt = config
    and config.agent
    and config.agent.auto_resume_on_limit
    and config.agent.auto_resume_on_limit.prompt
  if type(prompt) == "string" and vim.trim(prompt) ~= "" then
    return prompt
  end
  return "Continue from where you left off."
end

---変更ファイル一覧とpatchをチャットに書き出す
---
---2つのdiff経路（git snapshot / request_diff）の共通の出口。どちらも「repoルート相対の
---表示用パス」「絶対パス」「patch本文」の3つに畳んでからここに来る。
---@param callbacks Vibing.ChatCallbacks
---@param base_dir string patch内パスの基準ディレクトリ（絶対パス）
---@param files string[] 表示用の相対パス一覧
---@param abs_files string[] バッファリロード用の絶対パス一覧
---@param patch_content string|nil patch本文
---@param handle_id string|nil patchファイル名に使うハンドルID
function M._emit_diff_output(callbacks, base_dir, files, abs_files, patch_content, handle_id)
  if #files > 0 then
    BufferReload.reload_files(abs_files)
    local MAX_DISPLAY = 50
    local file_lines = {}
    for i = 1, math.min(#files, MAX_DISPLAY) do
      table.insert(file_lines, files[i])
    end
    if #files > MAX_DISPLAY then
      table.insert(file_lines, string.format("... (%d more)", #files - MAX_DISPLAY))
    end
    callbacks.append_chunk("\n\n### Modified Files\n\n" .. table.concat(file_lines, "\n") .. "\n")
  end

  if patch_content then
    local patch_dir = base_dir .. "/.vibing/patches"
    Fs.ensure_dir(patch_dir)
    local suffix = tostring(handle_id or ""):gsub("%W", ""):sub(-6)
    local patch_path = string.format("%s/%s_%s.patch", patch_dir, os.date("%Y%m%d_%H%M%S"), suffix)
    local f = io.open(patch_path, "w")
    if f then
      f:write(patch_content)
      f:close()
      callbacks.append_chunk("\n<!-- patch: " .. patch_path .. " -->\n")
    else
      vim.notify("[vibing] Failed to write patch file: " .. patch_path, vim.log.levels.WARN)
    end
  end

  vim.schedule(function()
    callbacks.add_user_section()
  end)
end

---ツリースナップショット差分（主経路）のModified Files出力とpatch生成
---
---request_diffと違い、Bashで書き換えられたファイルもここに載る。差分は
---「リクエスト前のツリー」と「今のツリー」の2つのgitオブジェクトの比較なので、
---どのツールが変更したかを一切知らなくてよい。
---@param callbacks Vibing.ChatCallbacks
---@param handle_id string|nil リクエストのハンドルID
---@param modified_file_paths table<string, boolean> ツールイベントで検知した変更ファイル
---@return boolean handled 差分を出力できたか。falseなら何も書いていないので、呼び出し側が
---  request_diff にフォールバックする（「変更が無かった」ではなく「取れなかった」の意味）
function M._finalize_snapshot_diff(callbacks, handle_id, modified_file_paths)
  local GitSnapshot = require("vibing.core.utils.git_snapshot")

  local base_dir = GitSnapshot.get_root(handle_id) or vim.fn.getcwd()
  local files, abs_files, patch_content, ok = GitSnapshot.generate(handle_id, modified_file_paths)
  GitSnapshot.clear(handle_id)

  if not ok then
    return false
  end

  M._emit_diff_output(callbacks, base_dir, files, abs_files, patch_content, handle_id)
  return true
end

---リクエスト単位diff（フォールバック経路）のModified Files出力とpatch生成
---git管理外のworking_dirと、同じworktreeで並行実行中のターンで使う。
---@param callbacks Vibing.ChatCallbacks
---@param handle_id string|nil リクエストのハンドルID
---@param modified_file_paths table<string, boolean> ツールイベントで検知した変更ファイル
function M._finalize_request_diff(callbacks, handle_id, modified_file_paths)
  local RequestDiff = require("vibing.core.utils.request_diff")
  local Git = require("vibing.core.utils.git")

  local session_cwd = callbacks.get_cwd and callbacks.get_cwd() or nil
  local base_dir = session_cwd or Git.get_root(nil) or vim.fn.getcwd()
  base_dir = vim.fn.fnamemodify(base_dir, ":p"):gsub("/$", "")

  local files, abs_files, patch_content = RequestDiff.generate(handle_id, base_dir, modified_file_paths)
  RequestDiff.clear(handle_id)

  M._emit_diff_output(callbacks, base_dir, files, abs_files, patch_content, handle_id)
end

---廃止されたfrontmatterキーを一度だけ警告する
---
---`mote_dirs` / `mote_cwd` は削除されたmote統合の設定で、今はどこからも読まれない。
---executeは1通ごとに走るので、warned_modesと同じく現れたキーの組み合わせごとに「一度だけ」
---出す。送信のたびに同じ警告を出さないための措置。
---@type table<string, boolean>
local warned_removed_frontmatter = {}

---テスト用: 警告済み集合をリセットする
function M._reset_removed_frontmatter_warnings()
  warned_removed_frontmatter = {}
end

---@param frontmatter table|nil
function M._warn_removed_frontmatter(frontmatter)
  if type(frontmatter) ~= "table" then
    return
  end
  local found = {}
  for _, key in ipairs({ "mote_dirs", "mote_cwd" }) do
    if frontmatter[key] ~= nil then
      table.insert(found, key)
    end
  end
  if #found == 0 then
    return
  end

  local shown = table.concat(found, ", ")
  if warned_removed_frontmatter[shown] then
    return
  end
  warned_removed_frontmatter[shown] = true
  vim.notify(
    string.format(
      "[vibing] Frontmatter '%s' is no longer used and can be removed — diffs now come from a git tree snapshot of the working directory, which also catches Bash-driven changes.",
      shown
    ),
    vim.log.levels.WARN
  )
end

---フロントマターのagentフィールドに基づいてアダプターを解決
---@param default_adapter table デフォルトアダプター（init.luaで初期化されたもの）
---@param callbacks Vibing.ChatCallbacks
---@param config table
---@return table adapter
function M._resolve_adapter(default_adapter, callbacks, config)
  local Modes = require("vibing.core.constants.modes")
  local adapter_factory = require("vibing.infrastructure.adapter.factory")
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

  if default_adapter and default_adapter.name == adapter_factory.adapter_name(agent_type) then
    return default_adapter
  end

  return adapter_factory.create(agent_type, config)
end

return M
