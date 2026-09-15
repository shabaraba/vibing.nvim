--- The xAI Grok Build CLI, spawned as `grok --single=<prompt> --output-format streaming-json`.
--- @module vibing.infrastructure.adapter.backends.grok

local GrokCommandBuilder = require("vibing.infrastructure.adapter.modules.grok_command_builder")
local GrokEventProcessor = require("vibing.infrastructure.adapter.modules.grok_event_processor")
local GrokLightweight = require("vibing.infrastructure.adapter.modules.grok_lightweight")
local GrokSettingsGenerator = require("vibing.infrastructure.hooks.grok_settings_generator")
local ToolVocabulary = require("vibing.infrastructure.adapter.modules.grok_tool_vocabulary")

---@type Vibing.BackendDescriptor
local M = {
  id = "grok",

  -- No `dynamic_permissions`: grok reaches no vibing-nvim MCP server and its hook is discovered
  -- from the project tree rather than registered per run.
  features = {
    streaming = true,
    tools = true,
    model_selection = true,
    context = true,
    session = true,
  },

  -- The builder emits a `--cwd` flag with the same value, so the flag and the process the flag
  -- describes cannot disagree. For a lightweight call both are the scratch directory.
  build = function(prompt, opts, session_id, config)
    return GrokCommandBuilder.build(prompt, opts, session_id, config)
  end,
  event_processor = GrokEventProcessor,

  resolve_cwd = GrokLightweight.resolve_cwd,

  -- Grok discovers <cwd>/.grok/hooks/*.json when the folder is trusted, so the hook is written
  -- rather than passed. Nothing to hand the builder.
  --
  -- Lightweight calls skip it too, matching claude and codex. The builder takes their tools away
  -- instead, and routing a title-generation tool call into the chat's approval UI would prompt
  -- the user about a request they never made. Skipping the write is not the whole of it: a
  -- lightweight call also runs from a directory that has no `.grok/hooks/` to discover, so the
  -- hook a previous ordinary chat left in the project can no longer be picked up (#588).
  prepare_hook = function(cwd, opts)
    local permission_mode = opts.permission_mode or "default"
    if permission_mode == "bypassPermissions" or opts.lightweight then
      return nil
    end
    local ok, err = pcall(GrokSettingsGenerator.ensure, cwd)
    if not ok then
      vim.notify(
        string.format("[vibing:grok] Failed to install PreToolUse hook: %s", tostring(err)),
        vim.log.levels.WARN
      )
    end
    return nil
  end,

  -- The half of the lightweight restriction that is not expressible as a flag: grok's
  -- `[compat.<vendor>]` cells resolve env var first, so this is the per-invocation switch #588
  -- was filed for the absence of. Only the child's environment moves.
  apply_env = function(env, opts)
    if opts.lightweight then
      GrokLightweight.apply_env(env)
    end
  end,

  vocabulary = ToolVocabulary,
  register_chat_bufnr = false,
  stdin = "",
}

return M
