--- The Pi coding agent, spawned as `pi --mode json -- <prompt>`.
---
--- Pi is a small agent harness rather than a vendor CLI: it holds the tools and the agent loop, and
--- the model comes from whatever provider its own `models.json` points at — including a local
--- OpenAI-compatible server such as `mlx_lm.server` or `llama-server`, which is why this backend
--- exists (#814).
---
--- Two things about it are unlike the other four, and both are load-bearing:
---
--- **No tool approval of its own.** Pi documents that it "does not ask for approval before every
--- tool call", and print/JSON/RPC modes cannot show even its trust prompt. So vibing.nvim's gate is
--- not an extra layer here, it is the only one — see `pi-extension/src/index.ts`. A turn that
--- cannot install it does not run ungated; `pi_command_builder.permission_args` takes the writing
--- tools away instead.
---
--- **Stdin must be closed.** Left open, Pi never reaches the model: measured against Pi 0.87.1, a
--- `--mode json` run with an inherited stdin produced no request and no output at all, silently,
--- until killed. Hence `stdin = ""`.
--- @module vibing.infrastructure.adapter.backends.pi

local PiCommandBuilder = require("vibing.infrastructure.adapter.modules.pi_command_builder")
local PiEventProcessor = require("vibing.infrastructure.adapter.modules.pi_event_processor")
local ToolVocabulary = require("vibing.infrastructure.adapter.modules.pi_tool_vocabulary")

---@type Vibing.BackendDescriptor
local M = {
  id = "pi",

  -- No `dynamic_permissions`: Pi ships no MCP client, so it reaches no vibing-nvim MCP server.
  -- (Third-party adapter packages add one, but a feature flag may not depend on what the user
  -- happens to have installed.)
  features = {
    streaming = true,
    tools = true,
    model_selection = true,
    context = true,
    session = true,
  },

  -- `pi --mode json [--provider P] [--model M] [--thinking L] [--session-id S]
  --     [--extension <bridge>] -- <prompt>`
  request = {
    binary = PiCommandBuilder.BINARY,
    parts = {
      { kind = "args", "--mode", "json" },
      { kind = "extra", fn = PiCommandBuilder.provider_args },
      { kind = "model", flag = "--model", names = "native" },
      -- Pi's `--thinking` accepts off/minimal/low/medium/high/xhigh/max, a strict superset of
      -- vibing's effort values, so the neutral value passes through with no mapping.
      { kind = "effort", flag = "--thinking" },
      { kind = "extra", fn = PiCommandBuilder.session_args },
      -- The permission bridge. `hook_arg` is the extension path the `extension_file` transport
      -- resolved. `unless = "lightweight"`: a utility call carries no gate flag at all, and is
      -- fenced by `--no-tools` instead.
      { kind = "hook_arg", flag = "--extension", unless = "lightweight" },
      { kind = "extra", fn = PiCommandBuilder.permission_args, unless = "lightweight" },
      vim.tbl_extend("force", { kind = "args", when = "lightweight" }, PiCommandBuilder.LIGHTWEIGHT_ARGS),
      -- `--` first, because Pi treats leading positional arguments beginning with `-` as flags and
      -- `@`-prefixed ones as file attachments.
      --
      -- `language_prefix`, because Pi has no system-prompt flag: `cli_command_builder` appends
      -- claude's language instruction to `--append-system-prompt`, and there is nowhere here to
      -- put it but the prompt itself. A local model is where it matters most — the harness is how
      -- one gets asked for a language it was not trained to volunteer.
      { kind = "prompt", terminator = "--", language_prefix = true },
    },
  },
  build = PiCommandBuilder.build,
  event_processor = PiEventProcessor,

  -- An in-process TypeScript extension loaded with `--extension`, which spawns the shared
  -- `bin/hooks/pre-tool-use.sh` itself and reads its exit code — hence dialect `claude`, the
  -- branch that describes exactly those exit codes.
  --
  -- `keep_in_bypass` is true for the reason codex's is: bypassPermissions bypasses the decision,
  -- not the git-snapshot baseline that the same round trip takes. Dropping it here would cost
  -- `### Modified Files`, `.vibing/patches/*.patch` and `gd` in that mode.
  --
  -- No `measured_wait_floor_sec`: nobody has timed how long Pi lets an extension handler block, so
  -- an approval still kills the turn and comes back as a retry. Unlike the other backends this is
  -- not a fail-open risk — the bridge denies on its own deadline — but the measurement is what
  -- `can_wait_for_approval` requires, and a guess is what that field exists to refuse.
  hook = { transport = "extension_file", dialect = "claude", keep_in_bypass = true },

  -- Tells the bridge where the shared script is and when to give up. Runs before
  -- `RpcEnvironment.bind`, so it cannot overwrite `VIBING_*` the adapter owns.
  apply_env = PiCommandBuilder.apply_env,

  vocabulary = ToolVocabulary,

  -- Pi has no MCP client of its own, so `nvim_ask_user_question` cannot reach it and there is no
  -- choice-list UI to name a chat buffer for. Same position as grok.
  register_chat_bufnr = false,

  -- Not `nil`: see the module comment. An open stdin makes Pi hang before its first request.
  stdin = "",
}

return M
