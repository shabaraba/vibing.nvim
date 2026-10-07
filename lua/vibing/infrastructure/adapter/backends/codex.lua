--- The OpenAI Codex CLI, spawned as `codex exec --json`.
--- @module vibing.infrastructure.adapter.backends.codex

local CodexCommandBuilder = require("vibing.infrastructure.adapter.modules.codex_command_builder")
local CodexEventProcessor = require("vibing.infrastructure.adapter.modules.codex_event_processor")
local CodexProviderNotice = require("vibing.infrastructure.adapter.modules.codex_provider_notice")
local ToolVocabulary = require("vibing.infrastructure.adapter.modules.codex_tool_vocabulary")
local ProjectCodexPermissions = require("vibing.core.utils.project_codex_permissions")

--- @param config Vibing.Config|nil
--- @return string|nil
local function profile_content(config)
  return vim.tbl_get(config or {}, "backends", "codex", "profile_content")
end

---@type Vibing.BackendDescriptor
local M = {
  id = "codex",
  process = "duplex",
  duplex = require("vibing.infrastructure.adapter.modules.codex_duplex_protocol"),

  features = {
    streaming = true,
    tools = true,
    model_selection = true,
    context = true,
    session = true,
    dynamic_permissions = true,
  },

  -- `codex exec --json`, with `resume <id>` as a subcommand and permissions as `-c` overrides.
  request = {
    binary = CodexCommandBuilder.BINARY,
    parts = {
      -- app-server does not implement exec's hook-trust bypass; verify trust over RPC.
      { kind = "args", "app-server", "--listen", "stdio://", when = "duplex" },
      { kind = "extra", fn = CodexCommandBuilder.resident_hook_args, when = "duplex" },
      { kind = "args", "exec", unless = "duplex" },
      { kind = "resume", subcommand = "resume", unless = "duplex" },
      { kind = "args", "--json", unless = "duplex" },
      -- The transport's fragment verbatim: the `-c hooks.PreToolUse` pair and the trust bypass.
      -- Never on a lightweight call, whatever was handed in: the conformance suite passes one to
      -- prove the request drops it, since a hook nothing can answer is what stalls the turn.
      { kind = "hook_arg", unless = { "lightweight", "duplex" } },
      -- One-shot selections are process flags. Resident selections go only through turn/start,
      -- so changing them does not change the pool's argv reuse key.
      { kind = "extra", fn = CodexCommandBuilder.oneshot_selection_args, unless = "duplex" },
      -- Utility calls neither inherit the chat's threshold nor override codex's compaction
      -- setting after --ignore-user-config.
      { kind = "extra", fn = CodexCommandBuilder.auto_compact_args, unless = "lightweight" },
      vim.tbl_extend("force", { kind = "args", when = "lightweight" }, CodexCommandBuilder.LIGHTWEIGHT_ARGS),
      -- One mapping per transport, chosen here rather than inside the builder: app-server has no
      -- `-s` and no native approval dialog, so its permission argv is a different shape, not a
      -- variation on this one.
      { kind = "extra", fn = CodexCommandBuilder.permission_args, unless = { "lightweight", "duplex" } },
      { kind = "extra", fn = CodexCommandBuilder.resident_permission_args, when = "duplex" },
      { kind = "extra", fn = CodexCommandBuilder.plugin_args, unless = "lightweight" },
      -- Codex's `developer_instructions` is reserved for the plugin material, so the language
      -- sentence rides on the prompt.
      { kind = "prompt", language_prefix = true, unless = "duplex" },
    },
  },
  build = CodexCommandBuilder.build,
  event_processor = CodexEventProcessor,

  -- A `-c hooks.PreToolUse=[…]` override with the trust bypass, the script staged inside the
  -- cwd (`codex_settings_generator`). Codex reads claude's hook schema, so the dialect is claude's.
  --
  -- Kept in bypassPermissions: the permission handler honours that mode and allows every call,
  -- but the same PreToolUse round trip is also where git_snapshot takes the turn's baseline.
  -- Removing the hook would bypass observation as well as approval, leaving this mode with no
  -- patch and therefore no `gd` preview.
  -- No `measured_wait_floor_sec`: how long codex lets a hook block has never been measured (the
  -- account was at its usage limit when the rest of the table was taken), so approvals here keep
  -- killing the turn. Run `tests/perf/hook_wait_ceiling.sh` before adding a number.
  hook = { transport = "config_override", dialect = "claude", keep_in_bypass = true },

  -- Codex's **own** approval requests, which are a third channel and not the hook (#861). Measured
  -- with `tests/perf/codex_approval_answer_after_delay.sh` against codex-cli 0.160.1: a decision
  -- delivered 960s after `item/commandExecution/requestApproval` arrived was acknowledged
  -- (`serverRequest/resolved`), the approved command ran, and the turn completed normally. The
  -- control cell at 0s passed in the same run, which is what makes that reading legible.
  --
  -- **A floor, not a ceiling.** 960 is `permissions.approval_wait_sec` (900) plus
  -- `NATIVE_APPROVAL_MARGIN_SEC` (60) — the whole budget the default configuration derives — so the
  -- gate sits exactly on the evidence, and raising `approval_wait_sec` turns the waiting off here
  -- rather than waiting past what was observed.
  native_approval = { measured_wait_floor_sec = 960 },

  -- No `mcp.measured_answer_wait_sec` either, so `nvim_ask_user_question` keeps killing the turn
  -- here (#788). Codex is the backend where this is a real gap rather than a formality: its
  -- choice-list UI **is** wired (`register_chat_bufnr`), so the only thing standing between it and
  -- answering in place is a measurement nobody has taken.
  --
  -- What to run before adding a number: `tests/perf/mcp_answer_after_delay.sh` with its `claude -p`
  -- invocation replaced by the equivalent `codex exec` one. Two cells, both required — the control
  -- (immediate answer) is what makes a failing arm readable, and the arm must use the production
  -- budget (`wait_budget.question_budget_sec()`, 960s by default) rather than a shorter convenient
  -- delay, because the number is a floor and a short cell would only license a short wait.

  -- The project-local sandbox profile (`.vibing/codex-permissions.toml`) is created with the
  -- project's `.vibing/` and backfilled on setup for projects created before it existed. Existing
  -- files, including empty ones, are never overwritten.
  on_project_open = function(project_root, config)
    ProjectCodexPermissions.ensure(project_root, profile_content(config))
  end,
  on_setup = function(cwd, config)
    ProjectCodexPermissions.ensure_existing(cwd, profile_content(config))
  end,
  -- The plugin argv is memoised per plugin-directory list and the permission profile per cwd;
  -- `:VibingReloadCommands` is what the user runs after changing either.
  clear_caches = function()
    require("vibing.infrastructure.adapter.modules.codex_plugin_config").clear_cache()
    require("vibing.infrastructure.adapter.modules.codex_permission_profile").clear_cache()
  end,

  vocabulary = ToolVocabulary,
  -- The same stable value is placed in developer_instructions by codex_plugin_config, so the
  -- shared nvim_ask_user_question route can resolve this turn without a per-turn identifier.
  register_chat_bufnr = true,
  stdin = "",

  -- Codex always emits "Reading additional input from stdin..." to stderr; filter it out so the
  -- exit handler does not treat the run as an error.
  stderr_filter = function(data)
    return (data:gsub("Reading additional input from stdin%.%.%.%s*", ""))
  end,

  -- `--ignore-user-config` drops the user's model_provider along with their MCP servers (#587),
  -- so say once where these calls are actually going. The argv is what decides, not
  -- `opts.lightweight` alone: the builder documents that flag as a stand-in for a narrower switch
  -- codex does not have yet, so reading the built command is what makes the warning disarm itself
  -- the day the flag stops being used. `lightweight` still guards it because the prompt is the
  -- last element of `cmd`, and a message consisting of exactly that flag would otherwise match.
  -- Fired after the spawn, since the probe exists to describe that call and must not delay it.
  --
  -- Absent config reads as enabled, not disabled: the default is on (`config_fields` in
  -- core/constants/agents.lua).
  after_spawn = function(cmd, cwd, opts, config)
    local notice_enabled = vim.tbl_get(config or {}, "backends", "codex", "provider_notice") ~= false
    if notice_enabled and opts.lightweight and vim.tbl_contains(cmd, "--ignore-user-config") then
      CodexProviderNotice.check(cmd[1], cwd)
    end
  end,
}

return M
