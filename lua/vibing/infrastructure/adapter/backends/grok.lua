--- The xAI Grok Build CLI, spawned as `grok --single=<prompt> --output-format streaming-json`.
--- @module vibing.infrastructure.adapter.backends.grok

local GrokCommandBuilder = require("vibing.infrastructure.adapter.modules.grok_command_builder")
local GrokEventProcessor = require("vibing.infrastructure.adapter.modules.grok_event_processor")
local GrokLightweight = require("vibing.infrastructure.adapter.modules.grok_lightweight")
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

  -- `grok --single=<prompt> --output-format streaming-json`, prompt first as one argv token so a
  -- hyphen-leading prompt is not misparsed as flags by clap.
  request = {
    binary = GrokCommandBuilder.BINARY,
    parts = {
      { kind = "prompt", flag_eq = "--single=" },
      { kind = "args", "--output-format", "streaming-json" },
      { kind = "model", flag = "--model", names = "native" },
      { kind = "effort", flag = "--effort" },
      { kind = "resume", flag = "--resume", fork = "--fork-session" },
      vim.tbl_extend("force", { kind = "args", when = "lightweight" }, GrokLightweight.ARGS),
      -- Grok has no `auto`; it falls back to asking rather than forwarding an unsupported value.
      { kind = "permission_mode", flag = "--permission-mode", map = GrokCommandBuilder.PERMISSION_MODE_FALLBACK, unless = "lightweight" },
      { kind = "extra", fn = GrokCommandBuilder.cwd_args },
      { kind = "extra", fn = GrokCommandBuilder.rules_args },
    },
  },
  build = GrokCommandBuilder.build,
  event_processor = GrokEventProcessor,

  -- Shared with the command builder, so the `--cwd` flag and the process the flag describes
  -- cannot disagree. For a lightweight call both are the scratch directory.
  resolve_cwd = GrokLightweight.resolve_cwd,

  -- A hook file grok discovers at <cwd>/.grok/hooks/ once the folder is trusted
  -- (`grok_settings_generator`); nothing in the argv references it. Not kept in
  -- bypassPermissions, as before.
  --
  -- Skipping the write for a lightweight call is not the whole of it: that call also runs from
  -- a directory that has no `.grok/hooks/` to discover, so the hook a previous ordinary chat left
  -- in the project can no longer be picked up (#588).
  -- No `measured_wait_floor_sec`: unmeasured (grok was not signed in on the measuring machine), so
  -- approvals here keep killing the turn. That grok's hook file carries claude's timeout is not
  -- evidence about grok — the file is written by claude's generator, and what a CLI *honours* is a
  -- separate question from what it is handed.
  hook = { transport = "project_dir", dialect = "claude", keep_in_bypass = false },

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
