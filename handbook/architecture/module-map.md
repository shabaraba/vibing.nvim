# Module Map and Key Entry Points

Moved out of `.claude/rules/architecture.md`. The always-loaded rules keep the layering and the
seams; this file is the directory listing, which is re-derivable from the tree and so does not
need to be in every request.

The tree is layered (`domain` / `application` / `infrastructure` / `presentation`), not the flat
`actions/` + `ui/` layout used before v4.

## Core

- `lua/vibing/init.lua` - Entry point, command registration, adapter selection
- `lua/vibing/config.lua` - Configuration defaults with type annotations
- `lua/vibing/core/constants/` - `agents.lua` (backend registry), `tools.lua` (VALID_TOOLS),
  `modes.lua`, `worktree.lua`
- `lua/vibing/core/utils/` - timestamp, language, git, git_snapshot, rate_limit, request_diff,
  `yaml.lua` (the one YAML-subset codec; see below), ...

## Adapter (`lua/vibing/infrastructure/adapter/`)

One adapter, driven by a descriptor per backend (ADR 009). Adding a backend is
`handbook/ADAPTER_DEVELOPMENT.md`.

- `cli_adapter.lua` - The one `stream()`: hook install, argv build, spawn, event context, registry
  and permission-opts registration, resume timeout. Built per descriptor by `define()`.
- `backends/<id>.lua` - The descriptor (`Vibing.BackendDescriptor`): `request` (argv parts),
  `event_processor`, `hook` (transport × dialect), `vocabulary`, `features`, `stdin`, env edits,
  and the project hooks (`on_project_open` / `on_setup` / `clear_caches`)
- `<id>_cli.lua` - Two-line compatibility shims returning the class for that descriptor
- `factory.lua` - Agent id → adapter class, through the descriptor
- `base.lua` - The abstract interface the class inherits
- `modules/request_builder.lua` - Applies a descriptor's `request.parts`: the shared value
  resolution (model, effort, resume, prompt) and the `extra` escape hatch
- `modules/<id>_command_builder.lua` - The argv pieces a flag table cannot express for that
  backend, plus a `build()` over its request spec (what the builder specs pin)
- `modules/command_builder_common.lua` - Language sentence, `@file:` context prefix, cached binary
  lookup
- `modules/stream_decoder.lua` - Wraps a decoder as the `processLine` `stream_handler` feeds
- `decoders/<id>_<format>.lua` - One CLI's JSON lines → `Vibing.CanonicalEvent[]`; pure, stateful
  only through the `state` it is handed
- `modules/event_renderer.lua` - Canonical events → chat text, `on_tool_use`, subagent counting,
  session storage, usage, cli info. The one place tool rendering is decided.
- `modules/<id>_event_processor.lua` - Shims: `stream_decoder.processor(decoder, vocabulary)`
- `modules/<id>_tool_vocabulary.lua` - Native tool name / payload key / path key → canonical
- `modules/cli_runtime.lua` - `execute`/`cancel`/`supports` + session delegations, installed onto
  the class; plus `kill_tree`, `spawn` (the guarded `vim.system` call — a spawn that raises leaves
  no process, so the exit handler never cleans up), and `report_build_failure`. The two ids it is
  handed are minted by `core/utils/identity.lua`
  (`handbook/architecture/processes-and-turns.md`)
- `modules/non_claude_model.lua`, `modules/reasoning_effort.lua` - The shared value rules the
  request builder applies
- `modules/ask_user_question_instructions.lua` - Shared Claude/Codex choice-list tool instruction
  and stable chat-buffer identity line
- `modules/session_manager.lua` - CLI sessions, keyed by the **process** that holds one open
- `modules/active_stream_registry.lua` - In-flight streams, keyed by **turn**, each carrying the
  process serving it (`processes-and-turns.md`)
- `../hooks/transports.lua` - The four hook transports a descriptor can name, over the four
  settings generators beside it

`cancel()` kills the CLI's descendants before the parent on every backend; killing only the parent
lets shells or MCP servers spawned by tools keep the stdout pipe open, and `vim.system()`'s exit
handler waits for that pipe to close. `execute()` cancels a run that outlives its timeout instead
of returning and leaving the process alive. `cli_runtime_spec.lua` runs both over every backend.

The descendant walk is asynchronous (`vim.system`) rather than blocking (`vim.fn.system`), because
`cancel()` can be reached from a `vim.schedule` callback and should not stall the main loop there.
The shell script walks descendants with `pgrep -P`, kills them deepest-first, then kills the
parent; `handle:kill(9)` is only a fallback chained to the shell's `on_exit`, preserving that
ordering. Separately, `cancel()` calls the adapter's wrapped `on_done` path immediately after
starting termination, so registry cleanup, permission-opt cleanup, timers, and chat UI state do
not depend on the process exit callback ever arriving.

## Chat (presentation + application)

- `presentation/chat/buffer.lua`, `view.lua`, `controller.lua` - Chat buffer and window
- `presentation/chat/modules/` - renderer, streaming_handler, frontmatter_handler, file_manager,
  approval_parser, keymap_handler, ...
- `application/chat/send_message.lua` - Request orchestration (opts, callbacks, diffs)
- `application/chat/use_cases/fork.lua` - Chat fork
- `application/chat/use_cases/handoff.lua` - Summary-carrying new chat (`:VibingChatHandoff`)
- `application/chat/auto_resume.lua` - Usage-limit auto-resume scheduler

## RPC / hooks

- `infrastructure/rpc/server.lua` - Async TCP server queried by hooks and the MCP server
- `infrastructure/rpc/handlers/permission.lua` - PreToolUse decisions, approval UI,
  `ask_user_question`
- `infrastructure/rpc/handlers/rate_limit.lua` - StopFailure receiver
- `infrastructure/rpc/hook_scope.lua` - The single definition of "which process, and which turn,
  is this inbound hook in", and of the one fallback (`processes-and-turns.md`)
- `infrastructure/hooks/settings_generator.lua` - Writes `.vibing/hook-settings.json`

## Context System

- `application/context/manager.lua` - Context manager (manual + auto from open buffers)
- `infrastructure/context/collector.lua` - Collects `@file:path` formatted contexts

## UI

- `ui/permission_builder.lua` - Interactive permission configuration UI
- `ui/patch_viewer/`, `ui/command_picker.lua`, `ui/chat_deletion_picker.lua`

## Key Entry Points

Quick reference for commonly edited files:

```text
Lua Plugin:
- lua/vibing/init.lua                    - Plugin initialization and commands
- lua/vibing/config.lua                  - Configuration schema and defaults
- lua/vibing/infrastructure/adapter/cli_adapter.lua                - The one CLI adapter
- lua/vibing/infrastructure/adapter/backends/claude.lua            - The reference descriptor
- lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua - Claude's system prompt / permission argv
- lua/vibing/presentation/chat/buffer.lua                          - Chat buffer implementation
- lua/vibing/application/chat/send_message.lua                     - Request orchestration

Node.js side (no agent wrapper — only these):
- bin/hooks/pre-tool-use.sh    - PreToolUse hook → RPC
- bin/hooks/stop-failure.sh    - StopFailure hook → RPC
- claude-plugin/mcp-server/src/index.ts      - MCP server entry point
- claude-plugin/mcp-server/src/tools/        - MCP tool implementations (buffer, lsp, window, chat)

Tests:
- tests/lua/**/*_spec.lua      - Lua tests (plenary.nvim)
- tests/*_spec.lua             - Older top-level Lua specs
- tests/*.test.mjs             - Node.js tests
- tests/e2e/*.spec.lua         - E2E tests against a spawned Neovim instance
```

## Key Patterns

**Adapter Pattern:** One `cli_adapter` class per backend descriptor implements the `Adapter`
interface — `execute()`, `stream()`, `cancel()`, `supports()` — from what the descriptor declares.

**Context Format:** Files are referenced as `@file:relative/path.lua` or `@file:path:L10-L25` for
selections.

**Interactive UI:** Permission Builder uses `vim.ui.select()` for picker-based configuration,
automatically updating chat frontmatter without manual YAML editing.

**One frontmatter codec (#717):** `core/utils/yaml.lua` decodes and encodes the YAML subset a chat
frontmatter uses — scalars, block maps, block sequences, and sequences whose elements are maps.
`infrastructure/storage/frontmatter.lua` wraps it with the frontmatter-specific parts (the `---`
delimiters, legacy key migration, `KEY_ORDER`, region scanning) and is the only public entry point;
`presentation/chat/modules/frontmatter_handler.lua` edits a **buffer's** frontmatter by going
through that same pair (parse → mutate → `serialize_lines` → replace the region) rather than by
splicing lines. Before #717 the buffer path was an independent line-oriented parser with no
guarantee it agreed with the file path on the same input, and neither could represent a list
element with fields of its own — which is why `orchestrated`'s `task` was encoded as `<path>|<task>`
in PR #712. A consequence of the unification: any write through the buffer path re-serializes the
whole frontmatter region, so keys come back in `KEY_ORDER` regardless of how the file was laid out.
Not for skill/agent Markdown — `core/utils/yaml_frontmatter.lua` stays separate, because it reads
two or three known scalars (including block scalars, which `yaml.lua` does not) out of files this
plugin never writes.

**Diff Viewer:** When Claude edits files, use `gd` (go to diff) on file paths in chat to open a
vertical split diff view showing changes before/after.

**Language Support:** Configure AI response language for chat, supporting multi-language
development workflows.
