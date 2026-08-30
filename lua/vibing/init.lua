local Config = require("vibing.config")
local notify = require("vibing.core.utils.notify")

---@class Vibing
---vibing.nvimプラグインのメインモジュール
---設定管理、アダプター初期化、コマンド登録を担当するエントリーポイント
---@field config Vibing.Config プラグイン設定オブジェクト（setup()で初期化）
---@field adapter Vibing.Adapter AIバックエンドアダプター（claude_cli, codex_cli, copilot_cli等）
local M = {}

---現在使用中のアダプターインスタンス
---setup()でconfig.adapterに基づいて初期化される
---@type Vibing.Adapter?
M.adapter = nil

---vibing.nvimプラグインを初期化
---設定のマージ、アダプター初期化、チャットシステム初期化、リモート制御初期化、ユーザーコマンド登録を実行
---アダプター読み込みに失敗した場合はエラー通知して初期化を中断
---@param opts? Vibing.Config ユーザー設定オブジェクト（nilの場合はデフォルト設定のみ使用）
function M.setup(opts)
  Config.setup(opts)
  M.config = Config.get()

  -- vibing filetype 専用の treesitter パーサは存在しないため markdown を割り当てる。
  -- これがないと vibing バッファで treesitter ハイライトも
  -- render-markdown.nvim のレンダリングも一切効かない。
  -- (vim.bo.syntax = "markdown" は旧来の syntax エンジンにしか効かない)
  pcall(vim.treesitter.language.register, "markdown", "vibing")

  -- チャットファイル自動検知（.md と .vibing の両方をサポート）
  -- フロントマターに vibing.nvim: true が含まれている場合にアタッチ
  local chat_detect = require("vibing.infrastructure.storage.chat_detect")
  chat_detect.setup()

  -- グローバルなwrap設定管理（ウィンドウ切り替え時に正しいwrap設定を適用）
  local wrap_group = vim.api.nvim_create_augroup("VibingWrapManager", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = wrap_group,
    pattern = "*",
    callback = function()
      local ok_ui, ui_utils = pcall(require, "vibing.core.utils.ui")
      if ok_ui then
        -- 現在のウィンドウとバッファでwrap設定を適用
        -- force=falseでis_chat_buffer()チェックを行う
        pcall(ui_utils.apply_wrap_config, 0, nil, false)
      end
    end,
    desc = "Apply correct wrap settings when entering any window",
  })

  -- MCP RPCサーバー起動とアダプター初期化はどちらも同期I/Oを伴う
  -- （ポートbindの探索ループ・レジストリファイル書き込み・アダプターの長いrequire連鎖）。
  -- セッション復元で ft=vibing バッファが開くと setup() が起動中に走るため、起動パスから外す。
  -- 同一コールバック内で順に実行するので、RPCサーバーが受信可能になった時点でadapterは必ず存在する。
  -- また後続の vim.schedule(auto_resume.restore 等) より先に登録されるため、実行順も従来通り。
  vim.schedule(function()
    if M.config.mcp and M.config.mcp.enabled then
      local rpc_server = require("vibing.infrastructure.rpc.server")
      local port = rpc_server.start(M.config.mcp.rpc_port)
      if port > 0 then
        notify.info(string.format("MCP RPC server started on port %d", port))
      end
    end

    local adapter_factory = require("vibing.infrastructure.adapter.factory")
    M.adapter = adapter_factory.create(M.config.adapter, M.config)
  end)

  -- Cleanup stale hook communication directories from previous sessions.
  -- 起動直後に必要な処理ではない（hookが動くのは最初のリクエスト時）ので、/tmp のscanと
  -- 削除を起動パスから外す。
  vim.schedule(function()
    pcall(function()
      require("vibing.infrastructure.adapter.modules.hook_cleanup").cleanup_stale_dirs()
    end)
  end)

  -- 前回クラッシュ・強制終了で残ったリクエストdiffのrefを掃除する。ここで「アクティブな
  -- リクエストは無い」と言えるのは自プロセスについてだけで、同じworktreeを別のNeovimが既に
  -- 開いていることはある。消してよいrefの判断は sweep 側（sweep_refs）が持っているので、
  -- ここは「起動したので声をかける」以上のことはしない。
  -- git呼び出しを2つ伴うので、hook cleanupと同じく起動パスからは外す。
  vim.schedule(function()
    pcall(function()
      require("vibing.core.utils.git_snapshot").sweep(nil)
    end)
  end)

  -- 使用量リミット待ちのチャットのタイマーを張り直す。
  -- 5時間/週次リミットのリセットはNeovimの再起動を跨ぐことが多いため、
  -- .vibing/pending-resume.json から復元する。VimEnter後に遅延させて起動を妨げない。
  vim.schedule(function()
    pcall(function()
      require("vibing.application.chat.auto_resume").restore()
    end)
  end)

  -- nvim-dapの停止イベントを購読する。nvim-dapがまだロードされていない可能性があるので
  -- VimEnter後に遅らせる（未インストールならsetup側がfalseを返して何もしない）
  if M.config.dap and M.config.dap.enabled then
    vim.schedule(function()
      pcall(function()
        require("vibing.application.debug.analyze").setup(M.config.dap)
      end)
    end)
  end

  -- 終了時にクリーンアップ
  local augroup = vim.api.nvim_create_augroup("VibingCleanup", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      -- CLIプロセスを全てキャンセル
      if M.adapter then
        M.adapter:cancel()
      end

      -- RPCサーバー停止
      if M.config.mcp and M.config.mcp.enabled then
        local rpc_server = require("vibing.infrastructure.rpc.server")
        rpc_server.stop()
      end
    end,
  })

  -- チャットコマンド初期化
  require("vibing.application.chat").setup()

  -- カスタムコマンド（.claude/commands/*.md）はここでは読まない。
  -- commands.lua が初回利用時にスキャンする（理由は同ファイルの ensure_custom_loaded 参照）。

  -- コマンド登録
  M._register_commands()

  -- 補完システム初期化（nvim-cmpが利用可能な場合はソースを登録）
  require("vibing.application.completion").setup()
end

---位置指定を取るコマンド（VibingChat/VibingChatFork/VibingSubagentChat）の補完候補
---@param arg_lead string
---@return string[]
local function complete_positions(arg_lead)
  local matches = {}
  for _, pos in ipairs(require("vibing.core.constants.chat").POSITIONS) do
    if pos:find("^" .. vim.pesc(arg_lead)) then
      table.insert(matches, pos)
    end
  end
  return matches
end

---プロジェクト固有のClaude Codeプラグインの雛形を作成する
---作成後は`--plugin-dir`の解決結果を捨てて、再起動なしで読み込めるようにする
---@param name string プラグイン名
function M.create_plugin(name)
  local scaffold = require("vibing.infrastructure.plugins.scaffold")
  local path, problem = scaffold.create(name)

  if not path then
    notify.error(problem or "failed to create plugin", "CreatePlugin")
    return
  end

  require("vibing.infrastructure.plugins.plugin_dirs").clear_cache()
  require("vibing.application.completion").clear_cache()

  notify.info(string.format("created %s", path), "CreatePlugin")

  -- 雛形はすでにディスク上にあるので、`:edit`の失敗（壊れたShaDa、autocmdのエラー）で作成を失敗扱いにしない
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path .. "/skills/example/SKILL.md"))
  if not ok then
    notify.warn(string.format("could not open the example skill: %s", err), "CreatePlugin")
  end
end

---Neovimユーザーコマンドを登録
---VibingChat, VibingContext等の全コマンドを登録
---チャット操作、コンテキスト管理を含む
function M._register_commands()
  -- チャット関連コマンド
  vim.api.nvim_create_user_command("VibingChat", function(opts)
    require("vibing.presentation.chat.controller").handle_open(opts.args)
  end, {
    nargs = "?",
    desc = "Open Vibing chat with optional position (current|right|left|top|bottom|back) or file",
    complete = function(arg_lead, cmd_line, cursor_pos)
      -- First argument: position or file
      local args = vim.split(cmd_line, "%s+")
      if #args == 2 then
        local matches = complete_positions(arg_lead)
        for _, file in ipairs(vim.fn.getcompletion(arg_lead, "file")) do
          table.insert(matches, file)
        end
        return matches
      end
      return {}
    end,
  })

  vim.api.nvim_create_user_command("VibingToggleChat", function()
    require("vibing.presentation.chat.controller").handle_toggle()
  end, { desc = "Toggle Vibing chat window" })

  vim.api.nvim_create_user_command("VibingDebugAnalyze", function()
    require("vibing.application.debug.analyze").analyze()
  end, { desc = "Ask the agent to analyze the stopped debug session" })

  vim.api.nvim_create_user_command("VibingDebugHelp", function()
    require("vibing.application.debug.analyze").help()
  end, { desc = "Ask the agent what to check next in the stopped debug session" })

  vim.api.nvim_create_user_command("VibingChatFork", function(opts)
    require("vibing.presentation.chat.controller").handle_fork(opts.args)
  end, {
    nargs = "?",
    desc = "Fork current vibing chat with optional position (current|right|left|top|bottom|back)",
    complete = function(arg_lead)
      return complete_positions(arg_lead)
    end,
  })

  vim.api.nvim_create_user_command("VibingSubagentChat", function(opts)
    require("vibing.presentation.chat.controller").handle_subagent_chat(opts.args)
  end, {
    nargs = "?",
    desc = "Continue a subagent this chat started, in its own buffer (current|right|left|top|bottom|back)",
    complete = function(arg_lead)
      return complete_positions(arg_lead)
    end,
  })

  -- count = 0 で「カウントを取るが既定は無し」になる。`]u` などに割り当てたとき
  -- 3]u が3セクション先へ飛ぶよう、他の `]`/`[` 系モーションと揃えている。
  vim.api.nvim_create_user_command("VibingChatJumpNextUser", function(opts)
    require("vibing.presentation.chat.controller").handle_jump_user("next", opts.count)
  end, { count = 0, desc = "Jump to the next User section in the chat buffer" })

  vim.api.nvim_create_user_command("VibingChatJumpPrevUser", function(opts)
    require("vibing.presentation.chat.controller").handle_jump_user("prev", opts.count)
  end, { count = 0, desc = "Jump to the previous User section in the chat buffer" })

  vim.api.nvim_create_user_command("VibingSlashCommands", function()
    require("vibing.presentation.chat.controller").show_slash_commands()
  end, { desc = "Show slash command picker" })

  vim.api.nvim_create_user_command("VibingSetFileTitle", function()
    require("vibing.presentation.chat.controller").handle_set_file_title()
  end, { desc = "Generate AI title and rename chat file" })

  vim.api.nvim_create_user_command("VibingSummarize", function(opts)
    require("vibing.presentation.chat.controller").handle_summarize(opts.args)
  end, {
    nargs = "?",
    desc = "Generate and insert summary from chat history (--with-title also renames the file)",
    complete = function(arg_lead)
      local matches = {}
      for _, flag in ipairs({ "--with-title" }) do
        if flag:find("^" .. vim.pesc(arg_lead)) then
          table.insert(matches, flag)
        end
      end
      return matches
    end,
  })

  vim.api.nvim_create_user_command("VibingDeleteChats", function(opts)
    require("vibing.presentation.chat.deletion_controller").handle_delete_command(opts, M.config)
  end, {
    nargs = "?",
    desc = "Delete chat files (use --unrenamed to delete all unrenamed files)",
    complete = function(arg_lead, cmd_line, cursor_pos)
      local flags = { "--unrenamed" }
      local matches = {}
      for _, flag in ipairs(flags) do
        if flag:find("^" .. vim.pesc(arg_lead)) then
          table.insert(matches, flag)
        end
      end
      return matches
    end,
  })

  -- mote統合（と :VibingCleanMote / :VibingMoteDir）は削除された。設定を残したまま
  -- アップデートした人がコマンドの消失に戸惑わないよう、代わりに何を見ればよいかを返す
  -- スタブだけ残す。
  for _, removed in ipairs({ "VibingCleanMote", "VibingMoteDir" }) do
    vim.api.nvim_create_user_command(removed, function()
      vim.notify(
        string.format(
          "[vibing] :%s was removed with the mote integration. Diffs now come from a git tree "
            .. "snapshot taken per request, which needs no setup and also catches Bash-driven "
            .. "changes. Use `gd` on a file path in the chat as before.",
          removed
        ),
        vim.log.levels.WARN
      )
    end, { nargs = "?", desc = "Removed: mote integration (see :help vibing-configuration)" })
  end

  -- コンテキスト関連コマンド
  vim.api.nvim_create_user_command("VibingContext", function(opts)
    require("vibing.presentation.context.controller").handle_add(opts)
  end, {
    nargs = "?",
    desc = "Add file or selection to context (or from oil.nvim)",
    complete = "file",
    range = true,
  })

  vim.api.nvim_create_user_command("VibingClearContext", function()
    require("vibing.presentation.context.controller").handle_clear()
  end, { desc = "Clear Vibing context" })

  -- その他のコマンド
  vim.api.nvim_create_user_command("VibingCancel", function()
    local view = require("vibing.presentation.chat.view")
    -- カレントバッファがチャットバッファなら優先
    local chat_buffer = view.get_current()
    -- カレントバッファがチャット外の場合は直近のチャットバッファを使用
    if not chat_buffer then
      chat_buffer = view._current_buffer
    end
    if chat_buffer then
      local adapter = chat_buffer:_get_active_adapter()
      if adapter then
        adapter:cancel(chat_buffer._current_handle_id)
      end
    elseif M.adapter then
      M.adapter:cancel()
    end
  end, { desc = "Cancel current Vibing request" })

  vim.api.nvim_create_user_command("VibingClearAnnotations", function()
    -- Reaches into the RPC handler rather than a presentation controller, unlike the commands
    -- around it. There is no presentation state to own here: annotations live entirely in an
    -- extmark namespace, and this command and the MCP tool both want the same one function. A
    -- controller would be a pass-through with nothing in it. Give annotations real UI state and
    -- this should grow one like the rest.
    local annotations = require("vibing.infrastructure.rpc.handlers.annotations")
    local result = annotations.clear_annotations({})
    local count = #result.cleared_buffers
    if count == 0 then
      notify.info("No annotations to clear")
    else
      notify.info(string.format("Cleared annotations in %d buffer(s)", count))
    end
  end, { desc = "Clear vibing.nvim inline review annotations from all buffers" })
  vim.api.nvim_create_user_command("VibingSchedule", function(opts)
    local view = require("vibing.presentation.chat.view")
    local chat_buffer = view.get_current()
    if not chat_buffer then
      notify.warn("Not in a chat buffer")
      return
    end

    local bufnr = chat_buffer:get_buffer()
    local chat_file_path = vim.api.nvim_buf_get_name(bufnr)
    if chat_file_path == "" then
      notify.warn("Save this chat before scheduling a request")
      return
    end

    local message = chat_buffer:extract_user_message()
    if not message or vim.trim(message) == "" then
      notify.warn("Write a message under the '## User' header first")
      return
    end

    local AutoResume = require("vibing.application.chat.auto_resume")
    local agent = M.config.agent or {}
    local grace = (agent.auto_resume_on_limit and agent.auto_resume_on_limit.grace_sec) or 10

    local fire_at, reason
    if opts.args ~= "" then
      local When = require("vibing.core.utils.when")
      fire_at, reason = When.parse(opts.args)
      if not fire_at then
        notify.warn("Invalid time: " .. tostring(reason))
        return
      end
    else
      -- 別のバックエンドのリセット時刻は、このチャットが待つべき時刻ではない
      local Modes = require("vibing.core.constants.modes")
      local LimitState = require("vibing.infrastructure.storage.limit_state")
      local chat_agent = Modes.resolve_agent(chat_buffer:parse_frontmatter(), M.config)
      local state = LimitState.get_active(vim.fn.fnamemodify(chat_file_path, ":h"), chat_agent)
      if not state then
        notify.warn("No usage limit on record. Give a time, e.g. ':VibingSchedule 30m'")
        return
      end
      fire_at = state.resets_at + grace
    end

    -- 予約本文はバッファにしか無いので、エントリを組む前に保存しておく。保存に失敗したまま
    -- 予約すると、再起動後にfire_scheduled()がディスク上の本文（空）を読み、
    -- "メッセージが空" として黙って予約が失われる。
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent! write")
    end)
    if vim.bo[bufnr].modified then
      notify.warn("Could not save this chat, so the scheduled message would not survive a restart. Not scheduling.")
      return
    end

    local ok, err = AutoResume.schedule_request(chat_file_path, fire_at, { quiet = true })
    if not ok then
      notify.warn("Could not schedule: " .. tostring(err))
      return
    end

    -- 逃げ道（今すぐ送る手順）まで案内する。<CR>側の予約通知と同じ文面に揃えてあり、
    -- どちらの経路で予約されたかによって案内が変わらないようにしている。
    notify.info(
      string.format(
        "Scheduled for %s (in %s). To send now: :VibingCancelResume, then <CR>.",
        os.date("%Y-%m-%d %H:%M", fire_at),
        AutoResume.format_duration(math.max(fire_at - os.time(), 0))
      )
    )
  end, {
    nargs = "?",
    complete = function()
      return { "15m", "30m", "1h", "2h", "5h" }
    end,
    desc = "Schedule this chat's unsent message to be sent later",
  })

  vim.api.nvim_create_user_command("VibingPendingResumes", function()
    local AutoResume = require("vibing.application.chat.auto_resume")
    local entries = AutoResume.list()
    if #entries == 0 then
      notify.info("No chats are waiting on a usage limit reset or a scheduled send")
      return
    end
    local now = os.time()
    local lines = {}
    for _, entry in ipairs(entries) do
      local when = entry.resets_at
          and string.format(
            "%s (in %s)",
            os.date("%Y-%m-%d %H:%M:%S", entry.resets_at),
            AutoResume.format_duration(math.max(entry.resets_at - now, 0))
          )
        or "reset time unknown"
      local kind = (entry.kind or "auto_resume") == "scheduled" and "scheduled" or "auto-resume"
      table.insert(
        lines,
        string.format(
          "%s - %s [%s, %s, retries used: %d]",
          vim.fn.fnamemodify(entry.chat_file_path, ":t"),
          when,
          kind,
          entry.limit_type or "unknown limit",
          entry.retry_count or 0
        )
      )
    end
    notify.info("Pending resumes:\n" .. table.concat(lines, "\n"))
  end, { desc = "List chats waiting on a usage limit reset or a scheduled send" })

  vim.api.nvim_create_user_command("VibingCancelResume", function(opts)
    local AutoResume = require("vibing.application.chat.auto_resume")

    if opts.args ~= "" and opts.args ~= "all" then
      notify.warn("Usage: :VibingCancelResume [all]")
      return
    end

    if opts.args == "all" then
      notify.info(string.format("Cancelled %d pending resume(s)", AutoResume.cancel(nil)))
      return
    end

    local view = require("vibing.presentation.chat.view")
    local chat_buffer = view.get_current()
    if not chat_buffer then
      notify.warn("Not in a chat buffer. Use ':VibingCancelResume all' to cancel every pending resume.")
      return
    end

    local path = vim.api.nvim_buf_get_name(chat_buffer:get_buffer())
    local Modes = require("vibing.core.constants.modes")
    if AutoResume.cancel(path, Modes.resolve_agent(chat_buffer:parse_frontmatter(), M.config)) > 0 then
      notify.info("Cancelled the pending request for this chat")
    else
      notify.info("This chat has nothing scheduled")
    end
  end, {
    nargs = "?",
    complete = function()
      return { "all" }
    end,
    desc = "Cancel this chat's pending auto-resume or scheduled request (or 'all')",
  })

  vim.api.nvim_create_user_command("VibingReloadCommands", function()
    local commands = require("vibing.application.chat.commands")
    local completion = require("vibing.application.completion")
    local skills = require("vibing.infrastructure.completion.providers.skills")
    local plugin_dirs = require("vibing.infrastructure.plugins.plugin_dirs")

    commands.reload_custom()

    -- Before the provider caches, not after: the skill and agent providers both re-resolve
    -- from this one, so clearing it second would refill them from the list being discarded.
    -- This is also what makes a plugin newly dropped into `.vibing/plugins` take effect.
    plugin_dirs.clear_cache()

    completion.clear_cache()
    skills.preload()

    notify.info("Commands and completions reloading...")
  end, { desc = "Reload custom slash commands and completion candidates" })

  vim.api.nvim_create_user_command("VibingCreatePlugin", function(opts)
    local name = vim.trim(opts.args)
    if name == "" then
      vim.ui.input({ prompt = "Plugin name: " }, function(input)
        if input and vim.trim(input) ~= "" then
          M.create_plugin(vim.trim(input))
        end
      end)
      return
    end
    M.create_plugin(name)
  end, {
    nargs = "?",
    desc = "Create a project-local Claude Code plugin under .vibing/plugins/",
  })

  vim.api.nvim_create_user_command("VibingCopyUnsentUserHeader", function()
    local timestamp = require("vibing.core.utils.timestamp")
    local header = timestamp.create_unsent_user_header()

    -- クリップボードプロバイダーを確認
    if vim.fn.has("clipboard") == 1 then
      vim.fn.setreg("+", header)
    else
      -- クリップボードサポートがない場合は無名レジスタに設定
      vim.fn.setreg('"', header)
    end

    notify.info("Copied to clipboard: " .. header)
  end, { desc = "Copy '## User <!-- unsent -->' to clipboard" })

  -- Daily Summary コマンド
  vim.api.nvim_create_user_command("VibingDailySummary", function(opts)
    require("vibing.presentation.daily_summary.controller").handle_daily_summary(opts.args)
  end, {
    nargs = "?",
    desc = "Generate daily summary from project chat files (default: today)",
  })

  vim.api.nvim_create_user_command("VibingDailySummaryAll", function(opts)
    require("vibing.presentation.daily_summary.controller").handle_daily_summary_all(opts.args)
  end, {
    nargs = "?",
    desc = "Generate daily summary from all chat files (default: today)",
  })
end

---現在のアダプターインスタンスを取得
---setup()で初期化されたアダプター（claude_cli, codex_cli, copilot_cli等）を返す
---setup()未実行の場合はnilを返す
---@return Vibing.Adapter? アダプターインスタンス（初期化済みの場合）またはnil
function M.get_adapter()
  return M.adapter
end

---現在の設定を取得
---setup()で初期化された設定を返す
---setup()未実行の場合はデフォルト設定を返す
---@return Vibing.Config 現在の設定オブジェクトまたはデフォルト設定
function M.get_config()
  return M.config or Config.defaults
end

return M
