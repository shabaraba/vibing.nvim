--- The xAI Grok Build CLI, spawned as `grok --single=<prompt> --output-format streaming-json`.
--- @module vibing.infrastructure.adapter.backends.grok

local GrokCommandBuilder = require("vibing.infrastructure.adapter.modules.grok_command_builder")
local GrokEventProcessor = require("vibing.infrastructure.adapter.modules.grok_event_processor")
local GrokLightweight = require("vibing.infrastructure.adapter.modules.grok_lightweight")
local ToolVocabulary = require("vibing.infrastructure.adapter.modules.grok_tool_vocabulary")

---@type Vibing.BackendDescriptor
local M = {
  id = "grok",

  -- The resident transport is `grok agent stdio`, which speaks Agent Client Protocol JSON-RPC.
  -- A ceiling, not a default: `ai.agents.grok.process = "duplex"` or a chat's `process:` frontmatter
  -- is what opts in. The one-shot `grok --single` path is unchanged and stays the default.
  process = "duplex",
  duplex = require("vibing.infrastructure.adapter.modules.grok_duplex_protocol"),

  -- No `dynamic_permissions`: grok's hook is discovered from the project tree rather than
  -- registered per run. It reaches vibing-nvim's MCP tools on the resident transport only --
  -- `grok --single` rejects `--plugin-dir`, and the servers travel in an ACP `session/new`.
  features = {
    streaming = true,
    tools = true,
    model_selection = true,
    context = true,
    session = true,
  },

  -- One-shot: `grok --single=<prompt> --output-format streaming-json`, prompt first as one argv
  -- token so a hyphen-leading prompt is not misparsed as flags by clap.
  --
  -- Duplex: `grok agent --no-leader [selections] stdio`. **Flags precede the subcommand**, which is
  -- why the `agent` pair opens this list and `stdio` closes it; clap rejects them the other way
  -- round. `--no-leader` is deliberate -- the default shares one backend process between every grok
  -- client on the machine, and a chat's resident process must be the chat's own.
  --
  -- Neither the prompt nor the session is in the duplex argv: both travel in `session/new` /
  -- `session/load` / `session/prompt`. Nor is `--permission-mode`, which `grok agent` does not
  -- accept at all -- there the gate is the project hook plus `grok_native_approval`.
  request = {
    agent_id = "grok",
    binary = GrokCommandBuilder.BINARY,
    parts = {
      { kind = "args", "agent", "--no-leader", when = "duplex" },
      { kind = "prompt", flag_eq = "--single=", unless = "duplex" },
      { kind = "args", "--output-format", "streaming-json", unless = "duplex" },
      { kind = "model", flag = "--model", names = "native" },
      { kind = "effort", flag = "--effort" },
      { kind = "resume", flag = "--resume", fork = "--fork-session", unless = "duplex" },
      vim.tbl_extend("force", { kind = "args", when = "lightweight" }, GrokLightweight.ARGS),
      -- Grok has no `auto`; it falls back to asking rather than forwarding an unsupported value.
      {
        kind = "permission_mode",
        flag = "--permission-mode",
        map = GrokCommandBuilder.PERMISSION_MODE_FALLBACK,
        unless = { "lightweight", "duplex" },
      },
      { kind = "extra", fn = GrokCommandBuilder.cwd_args, unless = "duplex" },
      { kind = "extra", fn = GrokCommandBuilder.rules_args, unless = "duplex" },
      { kind = "args", "stdio", when = "duplex" },
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
  -- **The resident transport honours this same file**, measured against grok 1.0.50: with a
  -- `.grok/hooks/*.json` deny hook in a trusted git repository, a `grok agent stdio` session had six
  -- tool calls in one turn refused (`write`, `list_dir`, `grep`, `run_terminal_command`;
  -- `"blocked":true`) and wrote nothing. So duplex needs no second transport -- which is just as
  -- well, since `--plugin-dir` is the only per-run alternative and `grok --single` rejects it.
  --
  -- Kept in bypassPermissions, as codex is and for codex's reason: the permission handler allows
  -- every call in that mode, but the same PreToolUse round trip is where `git_snapshot` takes the
  -- turn's baseline. Dropping the hook there would bypass observation as well as approval, leaving
  -- the mode with no `### Modified Files` and no `gd` preview.
  hook = { transport = "project_dir", dialect = "claude", keep_in_bypass = true },

  -- The half of the lightweight restriction that is not expressible as a flag: grok's
  -- `[compat.<vendor>]` cells resolve env var first, so this is the per-invocation switch #588
  -- was filed for the absence of. Only the child's environment moves.
  apply_env = function(env, opts)
    if opts.lightweight then
      GrokLightweight.apply_env(env)
    end
  end,

  vocabulary = ToolVocabulary,

  -- The choice-list UI routes by `chat_bufnr`, and on the resident transport grok can finally reach
  -- the tool that draws it (`grok_command_builder.rules_text` names it in the session's first
  -- prompt). Set without a `hook.measured_wait_floor_sec` or an `mcp.measured_answer_wait_sec`,
  -- which is the safe half of the pair: `transports.can_wait_for_approval` needs both, so approvals
  -- here keep today's kill-and-retry rather than waiting past evidence nobody has gathered.
  register_chat_bufnr = true,
  stdin = "",
}

return M
