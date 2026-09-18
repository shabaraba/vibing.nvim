--- The Claude Code CLI, spawned as `claude -p --output-format stream-json`.
---
--- The reference backend: the contracts every other descriptor is measured against (ADR 009)
--- are the behaviours this one has.
--- @module vibing.infrastructure.adapter.backends.claude

local CLICommandBuilder = require("vibing.infrastructure.adapter.modules.cli_command_builder")
local CLIEventProcessor = require("vibing.infrastructure.adapter.modules.cli_event_processor")
local AgentEnvironment = require("vibing.infrastructure.adapter.modules.agent_environment")
local TokenUsage = require("vibing.core.utils.token_usage")

---@type Vibing.BackendDescriptor
local M = {
  id = "claude",

  features = {
    streaming = true,
    tools = true,
    model_selection = true,
    context = true,
    session = true,
    dynamic_permissions = true,
  },

  -- `claude -p`, in the order the CLI has always been given it. The values behind `model`,
  -- `effort`, `resume` and `prompt` are resolved by request_builder; the extras are the parts
  -- composed from several sources, named here so they are listed rather than buried.
  request = {
    binary = CLICommandBuilder.BINARY,
    parts = {
      { kind = "args", "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages" },
      -- The resident transport's whole premise: with the prompt arriving on stdin the process has
      -- no reason to exit, so it serves the next turn too (`duplex_stream.lua`).
      { kind = "args", "--input-format", "stream-json", when = "duplex" },
      { kind = "model", flag = "--model", names = "claude" },
      { kind = "effort", flag = "--effort" },
      { kind = "resume", flag = "--resume", fork = "--fork-session" },
      -- Lightweight calls need no tools: --tools "" removes them rather than gating them, which
      -- is why it works where the alternatives don't (an empty --allowedTools alone does NOT
      -- block execution, and --permission-mode plan leaks plan-mode meta-commentary into the
      -- generated title). It names nothing, so unlike a denylist it cannot drift (#488).
      { kind = "args", "--tools", "", when = "lightweight" },
      { kind = "extra", fn = CLICommandBuilder.permission_args, unless = "lightweight" },
      { kind = "hook_arg", flag = "--settings", unless = "lightweight" },
      -- Without this the CLI swallows everything a subagent says and only its final tool_result
      -- surfaces. Opt-in because it makes long delegated turns much noisier.
      { kind = "args", "--forward-subagent-text", unless = "lightweight", when = { config = "agent.subagent.enabled" } },
      { kind = "extra", fn = CLICommandBuilder.plugin_dir_args, unless = "lightweight" },
      { kind = "extra", fn = CLICommandBuilder.mcp_config_args, unless = "lightweight" },
      { kind = "extra", fn = CLICommandBuilder.system_prompt_args },
      { kind = "extra", fn = CLICommandBuilder.setting_source_args },
      -- End of options marker, so a prompt starting with `---` is not parsed as flags. Dropped on
      -- the duplex transport, where the same text is composed by `request_builder.prompt_text` and
      -- written to stdin instead: an argv prompt would make the process answer once and exit.
      { kind = "prompt", terminator = "--", unless = "duplex" },
    },
  },
  build = CLICommandBuilder.build,
  event_processor = CLIEventProcessor,

  -- `.vibing/hook-settings-<instance>.json` handed over with `--settings`, in the script's own (claude)
  -- dialect. Registered in bypassPermissions too: that mode bypasses the decision, not the
  -- git-snapshot baseline the same PreToolUse round trip takes.
  -- 1090s, and **that is where we stopped watching, not where claude stopped waiting**: the hook
  -- was given a 1700s budget and took a SIGTERM from our own job stop at 1090s. A floor. Reading a
  -- number like this as a ceiling is the mistake that produced a whole rejected design once
  -- already (`handbook/architecture/approval-without-kill.md`).
  hook = {
    transport = "settings_file",
    dialect = "claude",
    keep_in_bypass = true,
    measured_wait_floor_sec = 1090,
  },
  seeds_project_plugins = true,

  apply_env = function(env, opts, config)
    -- Remove CLAUDECODE to allow nested invocation
    env.CLAUDECODE = nil

    -- Ahead of the git-instructions default below, so a declared variable reads exactly like one
    -- the user exported: the default still sees "already set, leave it alone".
    AgentEnvironment.apply(env, config, opts)

    -- The CLI computes a git status block (branch, `git status --short`, recent commits) once per
    -- process and puts it at the top of the system prompt, ahead of the whole conversation. A
    -- long-lived process pays for that once; vibing.nvim starts a new one every turn, so any turn
    -- that touched the tree changes those bytes and the entire prefix is re-written at
    -- cache-creation price. The CLI drops the block itself under CLAUDE_CODE_REMOTE for the same
    -- reason.
    --
    -- Both settings write the variable, because the CLI reads it as a tri-state: "1" suppresses
    -- the block, "0" forces it on, and unset falls through to `includeGitInstructions` in the
    -- user's settings.json — which `--setting-sources user,project,local` still loads. Writing
    -- nothing on the opt-in path would leave `git_instructions = true` unable to deliver what it
    -- promises for a user who has that key set to false. A value already in the environment wins
    -- over both.
    if env.CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS == nil then
      local git_instructions = config.agent and config.agent.git_instructions
      env.CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS = git_instructions and "0" or "1"
    end
  end,

  -- Created empty rather than on the `init` event: `compact_boundary` arrives mid-stream and must
  -- have somewhere to land even on a turn whose init line was missed or malformed.
  event_context_fields = function()
    return { tokenUsage = TokenUsage.new(), cliInfo = {} }
  end,

  -- Claude's tool names are the canonical vocabulary, so nothing to translate.
  vocabulary = nil,
  -- The one backend whose nvim_ask_user_question route is wired end to end.
  register_chat_bufnr = true,
  -- Reads its prompt from argv; stdin stays open.
  stdin = nil,
  -- The most capable process model this CLI can run, not the one it will: the default stays
  -- `oneshot` for every chat, and a resident process is reached only through
  -- `backends.claude.process` or a chat's `process:` frontmatter (`process_model.lua`).
  process = "duplex",
}

return M
