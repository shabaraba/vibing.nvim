--- The Command Code CLI: `commandcode -p --output-format json` (oneshot) or `commandcode acp`
--- (ACP over stdio, duplex).
--- @module vibing.infrastructure.adapter.backends.commandcode

local CommandBuilder = require("vibing.infrastructure.adapter.modules.commandcode_command_builder")
local CommandCodeEventProcessor = require("vibing.infrastructure.adapter.modules.commandcode_event_processor")
local ToolVocabulary = require("vibing.infrastructure.adapter.modules.commandcode_tool_vocabulary")

---@type Vibing.BackendDescriptor
local M = {
  id = "commandcode",
  -- A ceiling, not a default: `commandcode acp` is opt-in through `ai.agents.commandcode.process`
  -- or a chat's own `process:` frontmatter, exactly as it is for opencode.
  process = "duplex",
  duplex = require("vibing.infrastructure.adapter.modules.commandcode_duplex_protocol"),

  features = {
    streaming = true,
    tools = true,
    model_selection = true,
    context = true,
    session = true,
    dynamic_permissions = true,
    structured_output = false,
  },

  request = {
    agent_id = "commandcode",
    binary = CommandBuilder.BINARY,
    parts = {
      -- Every global flag goes **before** the `acp` subcommand: `commandcode acp` takes no options
      -- of its own (`acp --help` lists only `-h`), where the same flags ahead of it are accepted
      -- (measured on 1.88.2).
      { kind = "hook_arg", flag = "--mod", when = "hook_arg", unless = "lightweight" },
      { kind = "extra", fn = CommandBuilder.permission_args, unless = "lightweight" },
      { kind = "args", "--output-format", "json", unless = "duplex" },
      { kind = "args", "--no-session", when = "lightweight" },
      { kind = "model", flag = "--model", names = "native", unless = "duplex" },
      { kind = "effort", flag = "--effort", unless = "duplex" },
      -- `--session`, not `--resume`: measured on 1.88.2, `--resume` resolves through
      -- `hasCommandSession`, which is scoped to the project directory of the cwd — so resuming a
      -- chat whose `working_dir` changed (a worktree removed and recreated, a chat moved between
      -- worktrees) fails with `No session "<id>" found to resume.` and the session is thrown away.
      -- `--session` resolves the id against `listAllSessionsV3` (every project) and, when the
      -- transcript lives elsewhere, loads it with `loadExternalPrintSession` — the conversation
      -- follows the chat into the new directory. It takes the same id, and `--fork-session` covers
      -- it too (`dist/cli.mjs`).
      { kind = "resume", flag = "--session", fork = "--fork-session", unless = "duplex" },
      { kind = "args", "acp", when = "duplex" },
      -- `-p` takes the prompt as its value and reads stdin when it is absent; on duplex the prompt
      -- travels in the ACP `session/prompt` request instead, so this part drops out.
      { kind = "prompt", flag = "-p", language_prefix = true, unless = "duplex" },
    },
  },
  build = CommandBuilder.build,
  event_processor = CommandCodeEventProcessor,

  -- A generated TypeScript mod, handed over with `--mod`; it spawns the shared hook script. Both
  -- transports load it (`--mod` works with `-p` and with `acp`), and `keep_in_bypass` keeps the
  -- git-snapshot baseline running in bypassPermissions — which matters more here than elsewhere,
  -- because the CLI is always in bypass so that the bridge can be the gate.
  --
  -- `measured_wait_floor_sec` enables answering an approval **without killing the turn**, the same
  -- behaviour every other waiting backend has. Measured 2026-11-04 against Command Code 1.88.2: a
  -- mod's `beforeToolCall` was left blocking for **1090s and the CLI never cut it** (the probe set
  -- no timeout of its own), and the tool ran afterwards. Command Code imposes no timeout of its own
  -- on a mod hook (`dist/bundled/mod-builder/reference/hooks-and-events.md`), so the floor is the
  -- longest we watched, not a ceiling — exactly the reading claude's 1090 carries. Reproduce with
  -- `VIBING_PERF=1 tests/perf/hook_wait_ceiling.sh commandcode 1090` (`commandcode_turn_spec` and
  -- the ordering spec pin the derived answer).
  hook = {
    transport = "mod_file",
    dialect = "claude",
    keep_in_bypass = true,
    measured_wait_floor_sec = 1090,
  },

  apply_env = CommandBuilder.apply_env,

  vocabulary = ToolVocabulary,

  register_chat_bufnr = true,

  stdin = "",
}

return M
