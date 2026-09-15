--- The Claude Code CLI, spawned as `claude -p --output-format stream-json`.
---
--- The reference backend: the contracts every other descriptor is measured against (ADR 009)
--- are the behaviours this one has.
--- @module vibing.infrastructure.adapter.backends.claude

local CLICommandBuilder = require("vibing.infrastructure.adapter.modules.cli_command_builder")
local CLIEventProcessor = require("vibing.infrastructure.adapter.modules.cli_event_processor")
local AgentEnvironment = require("vibing.infrastructure.adapter.modules.agent_environment")
local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")
local PluginScaffold = require("vibing.infrastructure.plugins.scaffold")
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

  build = CLICommandBuilder.build,
  event_processor = CLIEventProcessor,

  -- Registered in bypassPermissions too: that mode bypasses the decision, not the git-snapshot
  -- baseline the same PreToolUse round trip takes. Skipped for a lightweight call, which owes
  -- "no hooks" (`core/types.lua`).
  prepare_hook = function(cwd, opts, config)
    if opts.lightweight then
      return nil
    end
    -- Seeding rides along with the hook settings because both are "this project is now using
    -- vibing.nvim" side effects, and this is the one place a real request passes through. Doing
    -- it in setup() would create `.vibing/` in every directory Neovim is ever started in.
    pcall(PluginScaffold.ensure, cwd, config)

    local ok, settings_path = pcall(SettingsGenerator.ensure, cwd)
    if not ok then
      vim.notify(
        string.format("[vibing:cli] Failed to create hook settings: %s", tostring(settings_path)),
        vim.log.levels.WARN
      )
      return nil
    end
    return settings_path
  end,

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
}

return M
