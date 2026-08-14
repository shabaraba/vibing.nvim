# Architecture

## Communication Flow

There is **no Node.js wrapper process**. vibing.nvim spawns the `claude` CLI directly with
`vim.system()` and parses its streaming JSON output:

```text
Neovim (Lua) ──vim.system()──> claude -p --output-format stream-json
     ▲                                    │
     │  stream-json lines (stdout)        │
     └────────────────────────────────────┘
     ▲
     │  hook callbacks (PreToolUse / StopFailure) over TCP
     └── bin/hooks/*.sh ──> RPC server (lua/vibing/infrastructure/rpc/)
```

The command is assembled in `cli_command_builder.lua`; the base flags are
`-p --output-format stream-json --verbose --include-partial-messages`, plus `--model`,
`--resume <session_id>` (`--fork-session` for forks), `--append-system-prompt`,
`--setting-sources`, permission flags, and `--settings .vibing/hook-settings.json`.

`cli_event_processor.lua` consumes the CLI's stream-json lines — `content_block_start`,
`content_block_delta` (`text_delta` / `input_json_delta`), `tool_use`, `tool_result`, `error`,
and `rate_limit_event` — and turns them into chunk/tool-display callbacks.

Everything that needs to call _back into_ Neovim mid-turn (permission decisions, approval UI,
`AskUserQuestion`, rate-limit reporting) goes through the RPC server rather than the stream.
`.vibing/hook-settings.json` (generated per cwd by `hooks/settings_generator.lua`) registers
`bin/hooks/pre-tool-use.sh` and `bin/hooks/stop-failure.sh`.

The PreToolUse hook is synchronous and blocks the tool call: it writes the hook payload to
`/tmp/vibing-hook-<port>/<request_id>.req`, sends a one-line JSON-RPC notification to the RPC port
with `nc`, then polls for `<request_id>.res` (up to 120s). It **fails closed** — if `nc` cannot
connect, or the response never arrives, the hook exits 2 and the tool is denied. `VIBING_HANDLE_ID`
is passed through so concurrent chats don't cross-wire each other's approval UI (see
`active_stream_registry.lua`). The comm directory path comes from
`infrastructure/rpc/comm_dir.lua` (the single source of truth shared by the handlers, the cleanup
routine and `bin/hooks/*.sh`). It is machine-wide shared state keyed by port, so it has two
escape hatches: `$VIBING_HOOK_COMM_DIR` overrides it outright (tests use this), and without a
listening port it falls back to a PID-suffixed path rather than a single shared `vibing-hook-0`.
The instance registry has the same treatment via `$VIBING_INSTANCES_DIR` (honoured by both
`rpc/registry.lua` and `mcp-server/src/handlers/instances.ts`).

The `.res` file carries **three** decisions, not two, and the difference is the whole permission
contract with the CLI:

- **`deny`** — the hook exits 2 with the reason on stderr, which is how a deny rule's `message`
  reaches the model.
- **`allow`** — the hook prints the JSON verbatim on stdout, and the CLI skips its own permission
  gate. Note that exiting 0 in silence is **not** an approval: the CLI reads it as "no opinion".
- **`defer`** — vibing.nvim permits the call but leaves the CLI's gate, and with it the user's own
  `settings.json` rules, in charge. The hook exits 0 silently.

Only vibing-nvim's own MCP tools get `allow`; everything else vibing.nvim permits gets `defer`.
Granting everything would override the user's `settings.json` deny rules, which
`--setting-sources user,project,local` still pulls in.

Those MCP tools are the exception because `--allowedTools` cannot express them reliably: it takes
literal prefixes, and the plugin-scoped one is `mcp__plugin_<marketplace>_vibing-nvim__`, a name
fixed when `claude plugin marketplace add` ran. `can_use_tool.is_vibing_nvim_mcp_tool` matches on
the suffix instead, so the grant survives a rename that `VIBING_NVIM_MCP_TOOL_PATTERNS` would not.
Before #564 every allowed call took the silent path, so under any mode but `bypassPermissions` the
CLI refused those tools while vibing.nvim's own log said "allow".

The match is on the name and nothing else, and that is worth stating plainly because an `allow`
skips the user's own `settings.json` rules. It requires the separator both registration styles put
before the server name (`_vibing-nvim__nvim_<tool>`), so a server merely _ending_ with the name
(`mcp__my-vibing-nvim__…`) does not match. A third-party server genuinely registered as
`vibing-nvim` and exposing `nvim_*` tools **would** be granted — nothing in a tool name says who
registered it. That needs an untrusted MCP server already in the user's own Claude Code config, so
it is accepted rather than solved.

`hook_cleanup.cleanup_stale_dirs()` (run at startup) treats a comm directory as stale only when
its owning Neovim is gone: it cross-checks `registry.list()`, which already filters to live PIDs,
so a concurrent instance's in-flight `.req`/`.res` files are never deleted.

**Backends:** `claude_cli.lua` (default), `codex_cli.lua`, `copilot_cli.lua` and `grok_cli.lua`
implement the adapter interface; `init.lua` picks one from `config.adapter`, and `send_message.lua` can switch
per request for non-claude agent types. Implementing the interface is not the same as feature
parity — `AskUserQuestion` is Claude-only, for reasons `features.md` records.

`lua/vibing/core/constants/agents.lua` is the single definition of what a backend is — module
path, export name, description, model candidates. `factory.lua`, `modes.lua` (`VALID_AGENTS`,
`VALID_MODELS`), `completion/providers/frontmatter.lua` and `infrastructure/init.lua` all derive
from it, so adding a backend is a one-file change (grok was added that way). It deliberately requires nothing, which
is what keeps the dependency one-way.

Two things stop backend identity leaking into shared code:

- **Tool vocabulary.** Backends name their tools differently (codex calls an edit `apply_patch`,
  copilot uses `bash`/`view`/`create`/`edit`/`web_search`, grok `search_replace`/
  `run_terminal_command`). Each adapter owns a `<backend>_tool_vocabulary.lua` and passes it to
  `set_active_opts` as a generic `_tool_vocabulary`; `rpc/handlers/permission.lua` just calls
  `normalize_payload`, `to_canonical` and `normalize_input` when the module offers them. The
  handler contains no backend name.

  The three are separate because backends disagree at three different levels, and the order
  matters — each step feeds the next:

  1. `normalize_payload` — the hook payload's own key names. Claude sends
     `tool_name`/`tool_input`; grok sends `toolName`/`toolInput`. Read straight through, the
     handler sees a nil tool name, so the two steps below get nothing to work on, every rule
     misses, and the turn stalls until the hook fails closed. This must run **first**.
  2. `to_canonical` — the tool's name (`apply_patch` → `Edit`).
  3. `normalize_input` — where the path lives inside the input. Granular `paths` rules read
     `input.file_path`; grok sends `path`/`target_file`/`filePath`.

  All three shapes were captured from the real CLIs, not read off their docs.

- **No MCP on every backend.** Grok, like codex, registers no `chat_bufnr` and reaches no
  vibing-nvim MCP server, so `grok_command_builder` deliberately keeps `--rules` to the
  backend-agnostic conventions. Naming `nvim_ask_user_question` there would hand the model a tool
  it cannot call — see `features.md` → AskUserQuestion Support.

- **Grok's hooks need a git repository.** `grok_settings_generator.lua` writes
  `<cwd>/.grok/hooks/` and marks the cwd trusted in `<$GROK_HOME|~/.grok>/trusted_folders.toml`,
  but grok discovers project hooks only inside a git repo (verified with `grok inspect`: the
  `project` entry appears under "Hooks" after `git init` and is absent before). Outside one the
  file is written and never read, which would silently allow every tool, so `ensure()` warns
  once per cwd instead. `$GROK_HOME` is grok's own documented override and is honoured — which is
  also the seam the specs use, since folder trust cascades to subdirectories and never expires.

- **`dynamic_permissions` capability.** `adapter:supports("dynamic_permissions")` is `false` for
  copilot, because its CLI has no per-run hook flag: permissions are fixed at launch with
  `--allow-all-tools` + `--deny-tool`, so `permission_mode`, the `ask` list and the approval UI do
  nothing there. Declared rather than left to be discovered by reading the adapter.

## Module Structure

The tree is layered (`domain` / `application` / `infrastructure` / `presentation`), not the flat
`actions/` + `ui/` layout used before v4.

**Core:**

- `lua/vibing/init.lua` - Entry point, command registration, adapter selection
- `lua/vibing/config.lua` - Configuration defaults with type annotations
- `lua/vibing/core/constants/` - `agents.lua` (backend registry), `tools.lua` (VALID_TOOLS),
  `modes.lua`, `worktree.lua`
- `lua/vibing/core/utils/` - timestamp, language, git, mote, rate_limit, request_diff, ...

**Adapter (`lua/vibing/infrastructure/adapter/`):**

- `base.lua` - Abstract adapter interface
- `claude_cli.lua` / `codex_cli.lua` / `copilot_cli.lua` / `grok_cli.lua` - Backend adapters
  (`new()` and `stream()`; everything else comes from `cli_runtime`)
- `modules/cli_runtime.lua` - `execute`/`cancel`/`supports` + session delegations, installed onto
  each adapter class; plus `new_handle_id`, `kill_tree`, `report_build_failure`
- `modules/command_builder_common.lua` - Language resolution, the response-language sentence, the
  `@file:` context prefix, and cached binary lookup — the backend-agnostic half of argv building
- `modules/cli_command_builder.lua` - Claude CLI argv construction (flags, system prompt)
- `modules/cli_event_processor.lua` - stream-json → chunk/tool events
- `modules/codex_command_builder.lua` / `modules/codex_event_processor.lua` - Codex equivalents
- `modules/non_claude_model.lua` - Model resolution for codex/copilot/grok
- `modules/<backend>_tool_vocabulary.lua` - Native tool name <-> canonical name, per backend
- `modules/session_manager.lua`, `modules/active_stream_registry.lua` - Session/handle tracking

**What a new backend still has to write** is `new()` and `stream()`. `stream()` stayed
per-adapter deliberately: its variation points — which settings generator runs before the build,
how many arguments the command builder takes, whether a `chat_bufnr` or a tool vocabulary gets
registered, whether stderr needs filtering — outnumber its shared lines, and the four adapters
genuinely disagree on the child environment. `cli_runtime` covers the pieces inside it that do
repeat.

Two behaviours were unified rather than parameterised while extracting them, because the split
was drift rather than intent. `cancel()` now kills the CLI's children before the parent on every
backend; claude killed only the parent, so the shells its tools spawned kept the stdout pipe open
and `vim.system()`'s exit handler — which waits for that pipe to close — never fired, leaving the
chat UI frozen. And `execute()` now cancels a run that outlives its timeout instead of returning
and leaving the process alive; only grok did that. `cli_runtime_spec.lua` runs both over every
backend.

The pkill is asynchronous (`vim.system`, grok's form) rather than blocking (`vim.fn.system`, what
codex and copilot used), because `cancel()` can be reached from a `vim.schedule` callback and
should not stall the main loop there. The cost is that the parent's `kill(9)` is not sequenced
after the children's: signal delivery is effectively immediate, so an orphan is theoretical rather
than observed, but it is a real ordering change and not something a test can pin while the call is
fire-and-forget. Revisit by chaining the parent kill onto the pkill's `on_exit` if orphans ever
show up.

**Chat (presentation + application):**

- `presentation/chat/buffer.lua`, `view.lua`, `controller.lua` - Chat buffer and window
- `presentation/chat/modules/` - renderer, streaming_handler, frontmatter_handler, file_manager,
  approval_parser, keymap_handler, ...
- `application/chat/send_message.lua` - Request orchestration (opts, callbacks, diffs)
- `application/chat/use_cases/fork.lua` - Chat fork
- `application/chat/auto_resume.lua` - Usage-limit auto-resume scheduler

**RPC / hooks:**

- `infrastructure/rpc/server.lua` - Async TCP server queried by hooks and the MCP server
- `infrastructure/rpc/handlers/permission.lua` - PreToolUse decisions, approval UI,
  `ask_user_question`
- `infrastructure/rpc/handlers/rate_limit.lua` - StopFailure receiver
- `infrastructure/hooks/settings_generator.lua` - Writes `.vibing/hook-settings.json`

**Context System:**

- `application/context/manager.lua` - Context manager (manual + auto from open buffers)
- `infrastructure/context/collector.lua` - Collects `@file:path` formatted contexts

**UI:**

- `ui/permission_builder.lua` - Interactive permission configuration UI
- `ui/patch_viewer/`, `ui/command_picker.lua`, `ui/chat_deletion_picker.lua`

## Key Entry Points

Quick reference for commonly edited files:

```text
Lua Plugin:
- lua/vibing/init.lua                    - Plugin initialization and commands
- lua/vibing/config.lua                  - Configuration schema and defaults
- lua/vibing/infrastructure/adapter/claude_cli.lua                 - Claude CLI adapter
- lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua - CLI argv / system prompt
- lua/vibing/presentation/chat/buffer.lua                          - Chat buffer implementation
- lua/vibing/application/chat/send_message.lua                     - Request orchestration

Node.js side (no agent wrapper — only these):
- bin/hooks/pre-tool-use.sh    - PreToolUse hook → RPC
- bin/hooks/stop-failure.sh    - StopFailure hook → RPC
- bin/list-commands.ts         - Slash command/skill enumeration for completion
- mcp-server/src/index.ts      - MCP server entry point
- mcp-server/src/tools/        - MCP tool implementations (buffer, lsp, window, chat)

Tests:
- tests/lua/**/*_spec.lua      - Lua tests (plenary.nvim)
- tests/*_spec.lua             - Older top-level Lua specs
- tests/*.test.mjs             - Node.js tests
- tests/e2e/*.spec.lua         - E2E tests against a spawned Neovim instance
```

## Session Persistence

Chat files are saved as Markdown with YAML frontmatter:

```yaml
---
vibing.nvim: true
session_id: <cli-session-id>
created_at: 2024-01-01T12:00:00
working_dir: .vibing/worktrees/fix-auth-session # Optional: relative path from git root for working directory
model: sonnet # sonnet, opus, haiku, or fable (from config.agent.default_model)
effort: xhigh # Optional: low, medium, high, xhigh, max (from config.agent.default_effort)
permission_mode: acceptEdits # default, acceptEdits, bypassPermissions, plan, dontAsk, or auto
permissions_allow:
  - Read
  - Edit
  - Write
  - Glob
  - Grep
permissions_deny:
  - Bash
language: ja # Optional: default language for AI responses
---
```

When reopening a saved chat (`:VibingChat <file>` or `:e`), the session resumes via the stored
`session_id`. The `model` field is automatically populated from
`config.agent.default_model` on chat creation, and can be changed
via `/model` slash command.

`effort` is the second cost/quality knob, passed to the CLI as `--effort`. Unlike `model` it is
**omitted unless configured**: with no `agent.default_effort` vibing.nvim passes no flag and the
CLI applies its own default, which Anthropic tunes over time — pinning a level here would freeze
it. Set it per chat with `/effort`. Lightweight calls (title generation, `/summarize`, daily
summary) use `agent.utility_effort` (default `low`) instead. It does **not** pair with a cheap
model: `utility_model` defaults to `sonnet`, because those calls summarize a noisy chat transcript
and haiku measurably picks the wrong subject. Low effort on a capable model is the trade actually
being made here. An unrecognised level is dropped with a warning rather than passed
through: the CLI accepts unknown levels silently and then ignores them.

**Lightweight calls are restricted differently per backend, because the CLIs differ in kind.**
Claude removes the tools outright with `--tools ""`. Codex cannot: probing its config schema with
`--strict-config` (which rejects unknown fields) against codex 0.147 shows `tools.shell`,
`tools.apply_patch`, `tools.view_image`, `tools.plan_tool` and `tools.mcp` are all unknown fields,
and `tools.web_search` is the only tool toggle that exists. So `codex_command_builder` fences the
call in instead — `sandbox_mode="read-only"`, `tools.web_search=false`, `approval_policy="never"` —
plus `mcp_servers={}` and `project_doc_max_bytes=0` — and `codex_cli.lua` skips hook
registration, matching `claude_cli.lua`. Those last two are codex's answers to claude's
`--strict-mcp-config`/`--mcp-config` and `--setting-sources ""`: without them a utility call
still reached the user's MCP servers and still read `AGENTS.md`.

`read-only` blocks writes **and** network, verified by running commands under `codex sandbox`
rather than read off the docs: a write reports `Operation not permitted` and `curl` returns
`000` where the same request outside the sandbox returns `200`. That matters because the shell
tool itself cannot be removed, so the sandbox is the only thing closing the exfiltration path
a prompt injection in the summarized transcript would otherwise have.

Three details there are not interchangeable. They are `-c` overrides rather than the `-s` flag
because `/summarize` passes a session id and `codex exec resume` does not accept `-s`. The
restriction ignores `permission_mode` entirely, `bypassPermissions` included: the user put the
_chat_ in that mode, and a title generated behind their back is not the call they made. And
`utility_model` still goes through the Claude-name filter, so its `sonnet` default becomes no
`-m` at all rather than a model codex would reject.

The model half of that lives in `modules/non_claude_model.lua`, shared by codex, copilot and grok.
It was three byte-identical private copies before, and #537 was filed against codex alone — so
teaching one copy about `lightweight` would have left the same bug live on the other two, with
nothing marking them stale. The restriction half stays per-backend on purpose: claude _removes_
tools with `--tools ""`, codex can only fence them, and no shared vocabulary spans that.
`core/types.lua` states the obligation each adapter owes for `lightweight` — no tools, no project
config, no hooks, `utility_model` — rather than the mechanism any one of them uses.

Configured permissions are recorded in frontmatter for
transparency and auditability. The optional `language` field ensures consistent AI response language
across sessions.

Note the singular `permission_mode`: that is the key `send_message.lua` actually reads, the key
completion offers, and the key the serializer orders. The legacy plural `permissions_mode` is
migrated to the singular form on parse (`infrastructure/storage/frontmatter.lua`) so old chat
files keep working, but it is no longer completed and should not be written.

**Working directory persistence:** The `working_dir` field stores the working directory as a relative
path from git root (e.g., `.vibing/worktrees/<branch>`). When a chat is reopened, the agent
and mote commands are executed in this directory. This ensures consistent file operations across
sessions, even when using a worktree or a custom directory.

## Concurrent Execution Support

vibing.nvim supports running multiple chat sessions simultaneously without interference:

**Multiple Chat Windows:**

- Each chat buffer maintains its own session ID
- Sessions are managed via unique handle IDs
- Old sessions are automatically cleaned up when starting new messages

**Session Management:**

- Handle IDs: `hrtime + random` ensures uniqueness across concurrent requests
- Session lifecycle: Created → Used → Automatically cleaned up when stale
- `cleanup_stale_sessions()` removes completed sessions while preserving active ones

See `docs/adr/002-concurrent-execution-support.md` for architectural details.

**Directory creation is a shared-state operation here.** `vim.fn.mkdir(path, "p")` is not atomic —
it walks the path creating each component and raises `E739` when another process creates one
first. That is routine rather than theoretical: the instance registry is machine-wide, a project's
`.vibing/` is shared by every chat open on it, and the test suite runs one child Neovim per spec
file. Measured at 9 failures in 200 concurrent calls, and it is what made `tests/view_spec.lua`
flake in CI (#576).

Every directory creation therefore goes through `core/utils/fs.lua`'s `ensure_dir`, and
`fs_spec.lua` fails the build if a direct `vim.fn.mkdir` reappears anywhere in `lua/`.

`ensure_dir` **retries**; catching the error and re-checking is not enough, which is worth knowing
before simplifying it. The component that collided is often an intermediate one, and the process
that won it has not necessarily reached the leaf yet — so the loser's `fs_stat` on the leaf
legitimately finds nothing. Catch-and-recheck still failed 3 times in 200; retrying measured 0 in 320.

Only the race is swallowed. Every other way `mkdir` fails — a read-only filesystem, a permission
denial, a file where the directory should go — raises `E739` as well, and `ensure_dir` re-raises
those with the original message. Callers were written against `vim.fn.mkdir`'s raising contract,
so returning a quiet `false` instead would leave eighteen of them continuing as though the
directory existed.

## Chat Fork

`:VibingChatFork` creates a branched conversation from the current chat session.

**Session Lifecycle:**

```text
Source Chat (session-abc)
  │
  ├─ User sends messages... CLI resumes session-abc
  │
  └─ :VibingChatFork right
       │
       Fork Chat (session_id: session-abc, forked_from: source.md)
         │
         ├─ First message → CLI: claude -p --resume session-abc --fork-session
         │                  → CLI returns new session-def
         │                  → frontmatter updated: session_id: session-def
         │                  → forked_from cleared
         │
         └─ Subsequent messages → CLI resumes session-def independently
```

**Key Design Decisions:**

- Fork inherits the source's `session_id` directly in frontmatter (no separate side-channel)
- The `forked_from` frontmatter field indicates a pending fork; `opts._is_fork` makes the command
  builder emit `--fork-session` right after `--resume`
- After the first response, `forked_from` is cleared and `session_id` is updated to the new value
- This avoids `BufReadPost`/`attach_to_buffer` lifecycle issues where in-memory state would be lost
- `ForkedChatScanner` automatically updates `forked_from` links when source files are renamed

**Implementation:**

- `lua/vibing/application/chat/use_cases/fork.lua` - Fork use case
- `lua/vibing/infrastructure/link/forked_chat_scanner.lua` - Link synchronization scanner
- `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua` - `--fork-session` flag

## Subagent Chat

`:VibingSubagentChat` opens a buffer bound to one subagent (`Task`/`Agent`) this chat started, so
the conversation with that agent can continue after the turn that spawned it ended.

**How the pieces connect:**

```text
Parent chat (session-abc)
  │
  ├─ Agent tool runs; its tool_result ends with
  │    agentId: ab2e... (use SendMessage with to: 'ab2e...' ...)
  │  → cli_event_processor writes `<!-- subagent: ab2e... type=general-purpose -->` into the
  │    chat text (subagent_marker.lua), so it is saved with the file
  │
  └─ :VibingSubagentChat
       │  subagent_finder scans the buffer for those markers (picker when there is more than one)
       │
       Subagent chat (session_id: session-abc, subagent_id: ab2e...)
         │
         └─ Every message → claude -p --resume session-abc  (NO --fork-session)
                          → --allowedTools gains Agent,Task,SendMessage,ToolSearch
                          → system prompt tells the model to relay via SendMessage(to: ab2e...)
```

**Why the session_id is shared permanently** (verified against the real CLI, not assumed): a
subagent's transcript lives under the _parent_ session's directory
(`.../<session_id>/tasks/<agentId>.output`). Resuming the parent session from a brand-new CLI
process and calling `SendMessage` works. Adding `--fork-session` does not — the forked session gets
a new id and `SendMessage` fails with `No transcript found for agent ID`. So unlike a fork, this
chat must never diverge, and `forked_from` is never written; `subagent_id` is the marker instead,
and `send_message.lua` sets `opts._subagent_id` rather than `opts._is_fork`.

**The cost of that:** two buffers now resume one `session_id` for good. Two
`claude --resume <same id>` processes would append to the same transcript concurrently, so
`send_message.lua` hard-refuses a send while another buffer's stream holds the same session
(`ActiveStreamRegistry.find_other_active_for_session`), before `start_response()` and without
touching the unsent `## User` line. Switching between the two buffers also re-diverges the shared
session's prompt cache, since each carries a different system prompt — accepted, not solved.

`SendMessage` resumes the agent in the background and returns immediately, so one request can now
produce two `result` events in a single CLI process lifetime. That is handled: `handle_result_event`
is idempotent and the exit handler fires once, on process exit, with both turns' output.

Built-in `Explore`/`Plan` agents are one-shot and return no `agentId`, so no marker is written and
they simply never appear in the picker.

Forking strips the markers from the copied body (`SubagentMarker.strip`): a fork diverges to its
own session on the first message, and those agents only exist under the original one, so keeping
them would offer a binding the CLI cannot resolve.

**Implementation:** `infrastructure/adapter/modules/subagent_marker.lua` (capture),
`presentation/chat/modules/subagent_finder.lua` (scan),
`application/chat/use_cases/subagent_chat.lua` (open, with a dedup check so one agent never gets two
rival buffers), `presentation/chat/controller.lua` → `handle_subagent_chat`.

## Multi-Agent Orchestration

One chat can create and drive other chats: `nvim_chat_create` (MCP) →
`infrastructure/rpc/handlers/chat.lua` → `application/chat/use_cases/create_chat.lua` →
`view.render`. The orchestrator briefs each worker with `nvim_chat_send_message` and polls it with
`nvim_get_buffer`. The workflow is the bundled `skills/vibing-orchestrate/SKILL.md`; there is no
command and no scheduler — the whole feature is three MCP calls and a skill.

Nothing new was needed to keep the workers apart. Each chat buffer already owns its own session
id and handle id (see "Concurrent Execution Support"), so parallel workers are the existing
concurrency guarantee being used rather than extended.

The use case is the fork/subagent shape: it returns a `ChatSession` and touches no presentation
code, and the RPC handler is what renders it. That is also why position validation sits in the
handler — it is an argument the RPC caller supplied, not a property of the session.

Four things it does differently from `:VibingChat`, each for a reason:

- **`position` defaults to `back`.** The chat exists as a listed buffer with no window. A worker
  the model created is not something the user asked to look at.
- **The chat file is written immediately** (`save_now` in the handler), matching `fork.lua`.
  `:VibingChat` leaves the file unwritten until `update_session_id` fires on the first response,
  so returning the path any earlier would name a file that does not exist.
- **`working_dir` is validated up front.** It is a git-root-relative path like the frontmatter
  field, resolved through `Git.resolve_working_dir`. A missing directory is rejected at creation;
  accepted, it would produce a chat that only fails on its first request, in a buffer the user
  is not watching.
- **The chat file still goes to the configured `save_dir`,** not inside `working_dir`. A worker
  attached to a worktree has to outlive `git worktree remove`, and this matches
  `vibing-worktree-create`, which only rewrites an existing chat's frontmatter. (The pre-existing
  and never-called `use_case.create_new_in_directory` does the opposite; `create_new` takes an
  optional `working_dir` instead.)

`view.render` now returns its `ChatBuffer` and replaces the `window` table before applying a
one-off `position`. It used to assign straight into `chat_buf.config.window.position`, and
`ChatBuffer` holds a reference to the live `config.chat` table — so a single `back` render changed
the user's default position for the rest of the session, right down to `Config.defaults`, which
survives a later `setup()`. Harmless enough at one `:VibingChat back` a day; not harmless when an
orchestrator opens three workers that way. Note that `vim.tbl_deep_extend("force", {}, cfg)` does
**not** fix it: with an empty base nothing collides, so every nested table is assigned by
reference and `config.window` stays the same table.

**Completion detection is a status field, not a text heuristic.** `nvim_get_buffer` passes
`include_chat_status` to `buf_get_lines`, which attaches `presentation/chat/modules/chat_status`'s
verdict: `"responding"` when `ChatBuffer:is_responding()` (either `_is_sending` or a
`_current_handle_id`), `"idle"` otherwise, and nothing at all for a buffer that is not a chat.
Both fields are needed — `_current_handle_id` is only set once the adapter spawns the CLI, so the
gap after `<CR>` would otherwise read as finished. Reading the transcript's shape instead would
call a turn that died on an error, or one part-way through silent tool calls, complete.

The flag is opt-in rather than a new return shape because the MCP server installs at Claude
Code's _user_ scope and updates independently of the plugin: without a parameter to key on, a
newer Neovim answering an older server would hand it an object where it calls `.join()`. Both
directions of that skew are covered — the Lua side returns the bare array unless asked, and the
Node side accepts either shape.

`idle` means "no request in flight", not "succeeded": a worker that failed, that is waiting on a
tool-approval prompt, or that asked a question is idle too. The skill says so, because the
distinction is not something the status can carry.

**Out of scope, deliberately:** workers cannot message the orchestrator back, there is no
event-driven completion notification, and the orchestrator does not poll inside its own turn — it
hands control back to the user and reports when asked. All three would need a channel that does
not exist yet; the MVP is "distribute, observe, report".

## Key Patterns

**Adapter Pattern:** All AI backends (`claude_cli`, `codex_cli`) implement the `Adapter` interface
with `execute()`, `stream()`, `cancel()`, and feature detection via `supports()`.

**Context Format:** Files are referenced as `@file:relative/path.lua` or `@file:path:L10-L25` for
selections.

**Interactive UI:** Permission Builder uses `vim.ui.select()` for picker-based configuration,
automatically updating chat frontmatter without manual YAML editing.

**Diff Viewer:** When Claude edits files, use `gd` (go to diff) on file paths in chat to open a
vertical split diff view showing changes before/after.

**Language Support:** Configure AI response language for chat,
supporting multi-language development workflows.

## Git Worktree Integration

Worktree-backed development goes through natural-language requests backed by the
`vibing-worktree-{list,create,attach,run,finish}` Claude Code skills bundled with this plugin
(`skills/vibing-worktree-*`), not through a vibing.nvim chat command. There is no bespoke
lifecycle script or metadata file — worktrees are created with plain
`git worktree add -b <branch> .vibing/worktrees/<branch>/` and removed with
`git worktree remove`; a worktree's existence on disk is its entire state. The chat's own
`working_dir` frontmatter field (unchanged by this) is what keeps a conversation attached to its
worktree across turns. See `skills/vibing-worktree-list/SKILL.md` (and its sibling `-create`,
`-attach`, `-run`, `-finish` skills) for the full list/create/attach/finish workflow.
