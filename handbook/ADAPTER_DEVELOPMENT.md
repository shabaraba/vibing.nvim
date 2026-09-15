# Adding a CLI Backend

A backend is a **descriptor**: one Lua table under `lua/vibing/infrastructure/adapter/backends/`
that says how a request is sent, how the response stream is read, and how the PreToolUse hook
reaches the CLI. The adapter itself — `cli_adapter.lua` — is shared and never names a backend.
The design and its limits are ADR 009 (`handbook/adr/009-declarative-backend-descriptor.md`).

The Claude backend's behaviour is the contract every other backend is measured against. The
conformance suite (`tests/lua/infrastructure/adapter/conformance/`) states that contract as tests
and runs them over every registered descriptor, so a new backend is checked by existing.

## What you write

| Piece                                 | Where                                                  | Data or code            |
| ------------------------------------- | ------------------------------------------------------ | ----------------------- |
| Registry entry (id, models, options)  | `core/constants/agents.lua`                            | data                    |
| Descriptor                            | `adapter/backends/<id>.lua`                            | data + a few functions  |
| Decoder (stream → canonical events)   | `adapter/decoders/<id>_<format>.lua`                   | code, small, pure       |
| Tool vocabulary                       | `adapter/modules/<id>_tool_vocabulary.lua`             | data                    |
| Argv extras the flag table cannot say | `adapter/modules/<id>_command_builder.lua`             | code, only what is left |
| Captured fixtures                     | `tests/fixtures/streams/<id>/`, the hook payload table | captures                |

A backend whose CLI registers hooks the way one of the existing four does needs **no new
transport**. One that needs a fifth way writes one module under `infrastructure/hooks/` and names
it in `hooks/transports.lua`.

## Before writing anything: measure the CLI

Every shape in the existing descriptors was read off the real CLI, not its documentation, and the
places where the two disagreed are exactly where a gate would have failed open
(`handbook/architecture/cli-integration.md` → "Backend Seams"). Capture these first, with the CLI
version, and keep the captures:

1. **A headless turn with a tool call**, as the CLI writes it to stdout (`stream-json`, JSONL or
   whatever the CLI offers). Which line names the session? Which carries text deltas? How does a
   tool call start and end, and are the two paired by an id? Where is usage reported, per request
   or once per turn? How does a failed turn look, and does the process exit non-zero?
2. **A PreToolUse hook payload**, by registering a script that dumps stdin. Key names
   (`tool_name`/`tool_input` or camelCase?), whether arguments arrive as a table or a JSON string,
   and the tool names for a shell command, a file edit and a file read.
3. **How the CLI reads a hook decision.** Does exit 2 deny? Does stderr reach the model? Does a
   JSON `allow` skip the CLI's own gate, and is a silent exit 0 "no opinion" or an approval? What
   happens on hook timeout — codex hangs, copilot fails _open_, claude denies.
4. **How a hook is registered for one run.** A settings file behind a flag, a config override, a
   per-run plugin directory, or only a file discovered from the project tree (and if so, under
   what trust conditions).
5. **How to take the tools away** for a lightweight call, and whether an empty list means "none"
   or is ignored (copilot ignores an empty list; grok fails open on a name it cannot map).
6. **How the CLI resumes a session** and which flags a resumed invocation refuses.

## The descriptor

```lua
--- lua/vibing/infrastructure/adapter/backends/<id>.lua
local Builder = require("vibing.infrastructure.adapter.modules.<id>_command_builder")
local Processor = require("vibing.infrastructure.adapter.modules.<id>_event_processor")
local Vocabulary = require("vibing.infrastructure.adapter.modules.<id>_tool_vocabulary")

---@type Vibing.BackendDescriptor
return {
  id = "<id>",
  features = { streaming = true, tools = true, model_selection = true, context = true, session = true },

  -- Request: an ordered list of parts. Data where the engine has a primitive, `extra` where it
  -- does not. See `request_builder.lua` for the primitives and their conditions.
  request = {
    binary = Builder.BINARY, -- { name = "<cli>", missing = "..." } or { resolve = fn, reset = fn }
    parts = {
      { kind = "args", "-p", "--output-format", "stream-json" },
      { kind = "model", flag = "--model", names = "native" }, -- "claude" only for claude itself
      { kind = "effort", flag = "--effort" },
      { kind = "resume", flag = "--resume" },
      { kind = "hook_arg", flag = "--settings", unless = "lightweight" },
      { kind = "args", "--tools", "", when = "lightweight" },
      { kind = "extra", fn = Builder.permission_args, unless = "lightweight" },
      { kind = "prompt", terminator = "--" },
    },
  },
  build = Builder.build,

  -- Response: the decoder behind the shared renderer, wrapped by stream_decoder.processor.
  event_processor = Processor,
  stdin = "", -- "" if the CLI reads stdin when no prompt argument is present
  stderr_filter = nil,

  -- Hook: transport × dialect. Both must be names `hooks/transports.lua` knows.
  hook = { transport = "settings_file", dialect = "claude", keep_in_bypass = true },

  vocabulary = Vocabulary,
  register_chat_bufnr = false, -- true only once nvim_ask_user_question is wired for this CLI
}
```

Then register it in `core/constants/agents.lua` (`adapter_module`, `descriptor_module`,
`command_builder_module`, `export_name`, `description`, `models`, and `config_fields` for any
option of its own), add the two-line `adapter/<id>_cli.lua` and `adapter/modules/<id>_event_processor.lua`
shims the other backends have, and run `npm run test:lua`. The conformance suite tells you which
contracts the descriptor does not yet meet.

## The decoder

A decoder is `{ decode = function(msg, state) return events end }`: one JSON line in, a list of
canonical events out, no rendering, no callbacks. The event set is `Vibing.CanonicalEvent` in
`event_renderer.lua`: `session`, `first_response`, `text`, `thinking`, `tool_start`, `tool_end`,
`subagent_text`, `usage`, `cli_info`, `rate_limit`, `error`. Emit tool names in the CLI's own
vocabulary; the renderer canonicalises them through the same table the permission handler uses,
so a tool is called the same thing in the chat and in a rule.

Keep whatever must be remembered across lines in `state` (copilot remembers which messages already
streamed; codex remembers which items started). `usage` is either `{ record = <one request> }`,
accumulated like claude's, or `{ accumulator = TokenUsage.cumulative(totals) }` for a CLI that
reports one running total per turn.

## The vocabulary

Three optional functions, applied in this order by `permission.normalize_hook_input`:
`normalize_payload` (the payload's own key names), `to_canonical` (the tool's name),
`normalize_input` (where the path lives). Every entry should come from a captured payload; an alias
the CLI never sends is inert, a missing one lets a deny rule fall open.

## What stays code, and where

- **Hook transport quirks** live in the transport module: codex hangs on an untrusted hook or a
  script outside its writable roots, copilot rejects a matcher and fails open on timeout, grok
  needs a trusted git repository.
- **Permission-mode mapping** onto a sandbox that is not Claude's is an `extra`
  (`codex_command_builder.permission_args`).
- **Lightweight fencing** is `args` when the CLI has a flag for it and an `extra` when it needs a
  scratch directory or environment (grok).
- **Anything that names a `vibing.nvim` MCP tool in a prompt** must only be sent to a CLI that can
  reach the server (`.claude/rules/features.md` → AskUserQuestion).

## Per-backend options

Declare them as `config_fields` on the registry entry; they surface as `backends.<id>.<field>` in
`setup()`, with defaults and validation derived from the declaration (`kind`: `string`, `boolean`,
`path_or_false`, `executable_or_auto`). `config.lua` never names a backend.
