--- The OpenAI Codex CLI, spawned as `codex exec --json`.
--- @module vibing.infrastructure.adapter.backends.codex

local CodexCommandBuilder = require("vibing.infrastructure.adapter.modules.codex_command_builder")
local CodexEventProcessor = require("vibing.infrastructure.adapter.modules.codex_event_processor")
local CodexProviderNotice = require("vibing.infrastructure.adapter.modules.codex_provider_notice")
local CodexSettingsGenerator = require("vibing.infrastructure.hooks.codex_settings_generator")
local ToolVocabulary = require("vibing.infrastructure.adapter.modules.codex_tool_vocabulary")

---@type Vibing.BackendDescriptor
local M = {
  id = "codex",

  features = {
    streaming = true,
    tools = true,
    model_selection = true,
    context = true,
    session = true,
    dynamic_permissions = true,
  },

  build = CodexCommandBuilder.build,
  event_processor = CodexEventProcessor,

  -- Lightweight calls skip hook registration, matching claude. The builder fences them into a
  -- read-only sandbox instead, and routing a title-generation tool call into the chat's approval
  -- UI would prompt the user about a request they never made.
  --
  -- Kept in bypassPermissions: the permission handler honours that mode and allows every call,
  -- but the same PreToolUse round trip is also where git_snapshot takes the turn's baseline.
  -- Removing the hook would bypass observation as well as approval, leaving this mode with no
  -- patch and therefore no `gd` preview.
  --
  -- If staging fails there is no script for codex to run, and registering the hook anyway is
  -- exactly the case that hangs. So a failure warns and drops the hook -- the turn runs ungated,
  -- which is bad, but it runs. See CodexSettingsGenerator.ensure.
  prepare_hook = function(cwd, opts)
    if opts.lightweight then
      return nil
    end
    local ok, args_or_err = pcall(CodexSettingsGenerator.get_hook_args, cwd)
    if ok then
      return args_or_err
    end
    vim.notify(
      string.format(
        "[vibing:codex] Failed to install the PreToolUse hook, so this turn is not gated by vibing.nvim: %s",
        tostring(args_or_err)
      ),
      vim.log.levels.WARN
    )
    return nil
  end,

  vocabulary = ToolVocabulary,
  -- The route is not wired for codex; the developer message tells the model not to call the tool
  -- (see codex_plugin_config), so registering a value nothing consumes would only look like a
  -- working route.
  register_chat_bufnr = false,
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
  -- Absent config reads as enabled, not disabled: the default is on (see config.lua).
  after_spawn = function(cmd, cwd, opts, config)
    local notice_enabled = vim.tbl_get(config or {}, "agent", "codex_provider_notice", "enabled") ~= false
    if notice_enabled and opts.lightweight and vim.tbl_contains(cmd, "--ignore-user-config") then
      CodexProviderNotice.check(cmd[1], cwd)
    end
  end,
}

return M
