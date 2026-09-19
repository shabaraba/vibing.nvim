# Architecture

Invariants and a map. Every "why" is one link away; read the linked file before changing that path.

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

`cli_command_builder.lua` assembles the argv; `cli_event_processor.lua` turns stream-json lines
into chunk/tool events. Everything that needs to call _back into_ Neovim mid-turn (permission
decisions, approval UI, `AskUserQuestion`, rate-limit reporting) goes through the RPC server rather
than the stream, registered by `.vibing/hook-settings-<instance>.json`
(`hooks/settings_generator.lua`).

The hook contract is `handbook/architecture/cli-integration.md`. Three invariants from it apply
whenever this path is touched:

- **The hook fails closed.** If `nc` cannot connect or no response arrives, it exits 2 and the
  tool is denied. Do not add a path that exits 0 on an internal failure.
- **The `.res` file carries three decisions, not two** — `deny`, `allow` and `defer`. Exiting 0
  in silence is `defer` ("no opinion"), _not_ an approval.
- **Only vibing-nvim's own MCP tools get `allow`; everything else permitted gets `defer`.**
  What an `allow` skips is the CLI's **allowlist**, not the user's deny rules. Measured against
  claude 2.1.236, the gate is ordered: toolset construction → PreToolUse hook → granular deny rules
  → `can_use_tool`. A **tool-name** deny is out of reach of any hook verdict — the tool is removed
  when the toolset is built and the hook never runs for it. A **granular** rule (`Bash(rm -rf:*)`)
  is evaluated _after_ the hook and **outranks an `allow` written there**. So the reason to withhold
  `allow` on the ordinary path is not safety from a deny rule: it is that nothing has looked at the
  call, and the user's own allowlist should still get its say. The one path that does write `allow`
  for an ordinary tool is an approval a human answered by eye (`permissions.md`). The ordering, the
  control cell that establishes it and the two limits it is measured under:
  `handbook/architecture/approval-without-kill.md`.

The comm directory path has exactly one definition, `infrastructure/rpc/comm_dir.lua`, shared by
the handlers, the cleanup routine and `bin/hooks/*.sh`.

## Backends and Their Seams

There is one adapter, `cli_adapter.lua`, driven by a descriptor per backend
(`adapter/backends/<id>.lua`, ADR 009). Implementing the descriptor is not the same as feature
parity — the `AskUserQuestion` choice-list UI is wired for Claude and Codex, but not Grok
(`handbook/features/chat-ui.md`). Adding a backend is `handbook/ADAPTER_DEVELOPMENT.md`; the
Claude backend's behaviour is the contract, pinned by `tests/lua/infrastructure/adapter/conformance/`
over every registered descriptor.

- **`core/constants/agents.lua` is the single definition of what a backend is** — module paths,
  export name, description, model candidates, and its `config_fields` (what `backends.<id>.*`
  accepts). `factory.lua`, `modes.lua`, `config.lua`, `completion/providers/frontmatter.lua` and
  `infrastructure/init.lua` all derive from it. It deliberately requires nothing, which keeps the
  dependency one-way.
- **A descriptor holds data; a decoder holds no rendering.** `request.parts` is the argv in order,
  `hook` names a transport and a dialect from `hooks/transports.lua`, and the decoder
  (`adapter/decoders/`) turns one JSON line into `Vibing.CanonicalEvent`s and stops.
  `event_renderer.lua` is the one place a tool call's appearance, `on_tool_use` and subagent
  counting are decided; a decoder that draws its own header reintroduces the per-backend drift
  P1 removed.
- **Tool names cross the seam in the CLI's own vocabulary and are canonicalised once.** The
  renderer and `permission.normalize_hook_input` translate through the same
  `<backend>_tool_vocabulary.lua`, so a tool is called the same thing in the chat and in a rule.
- **Nothing outside `adapter/`, `hooks/` and `agents.lua` names a backend.** Usage reporting keys
  on `TokenUsage.is_cumulative`, per-backend options live under `backends.<id>`, and project
  files come from the descriptor's `on_project_open` / `on_setup` / `clear_caches`.
- **A backend name belongs in that backend's own module; shared code takes what it is handed.**
  `rpc/handlers/permission.lua` contains no backend name.
- **`bin/hooks/pre-tool-use.sh` is the one deliberate exception**: the deny _signalling_
  convention differs (claude: exit 2 + stderr; copilot: exit 0 + stdout), and that is shell
  semantics.
- **Each `<backend>_tool_vocabulary.lua`'s three normalizations are order-dependent.**
  `normalize_payload` (key names) must run before `to_canonical` (tool name) and `normalize_input`
  (where the path lives), or every rule misses and the turn stalls until the hook fails closed.
  The order lives once, in `permission.normalize_hook_input`.
- **Grok discovers project hooks only inside a git repository** (outside one the gate would
  silently allow everything, so `ensure()` warns), and **copilot's hook is injected as a throwaway
  plugin** under `.vibing/copilot-plugin-<instance>/` via `--plugin-dir`, with a schema that is not
  claude's.
- **Every generated file under `<cwd>/.vibing/` whose contents depend on configuration is keyed by
  Neovim instance** (`rpc/instance_key.lua`, the same key `comm_dir` uses). The hook settings carry
  a timeout derived from `permissions.approval_wait_sec`, while the script's own deadline reaches
  the CLI child in its environment and is **fixed at spawn** — so one shared file lets a second
  Neovim with a lower value put the CLI's deadline ahead of the script's, which is the ordering
  every CLI measured **fails open** under. Whether a CLI re-reads its settings per turn is
  unmeasured; the key makes the question not arise. codex is immune already, its hook travelling in
  each run's argv.
- **Codex's hook key is `hooks.PreToolUse` and it travels with
  `--dangerously-bypass-hook-trust`.** Both halves fail silently on their own: codex drops an
  unrecognised `hooks.*` key without a warning (the snake_case spelling meant no hook fired at all
  — no permission gate, and no diff baseline, so no `.vibing/patches/*.patch` and no `gd` float),
  and a registered-but-untrusted hook makes `codex exec` **hang** rather than skip. So
  `codex_settings_generator.get_hook_args()` returns the flag and the `-c` pair as one fragment;
  do not split them. Verify with `hooks/list` on `codex app-server`, never by eye.
- **The Codex hook script is copied to `<cwd>/.vibing/codex-pre-tool-use.sh` before launch.** A
  hook command outside that turn's writable roots makes sandboxed `codex exec` hang instead of
  reporting a spawn error. Keep staging synchronous and atomic; if it fails, omit the hook rather
  than registering a command that cannot run. Keep the hook in `bypassPermissions`: that mode
  bypasses the decision, not the git-snapshot baseline carried by the same PreToolUse round trip.
- **`codex_tool_vocabulary.lua` has no `normalize_input`, deliberately.** A codex edit carries no
  path in `tool_input` — the paths are inside the apply_patch envelope in `command`, and there may
  be several. So granular `paths` rules do not match codex edits. Filling `file_path` from the
  first path would let a deny rule be evaded by patch ordering; the fix belongs in `matchers.lua`.

Why each seam exists and which CLI version each shape was captured from:
`handbook/architecture/cli-integration.md` → "Backend Seams".

## Plugin Loading and Command Discovery

vibing.nvim's own Claude Code plugin is **not installed**: `cli_command_builder` passes
`--plugin-dir <path>` once per directory resolved by `infrastructure/plugins/plugin_dirs.lua`.

- **`plugin_dirs.lua` is the single definition of "which plugin directories apply here."** Order
  is fixed at self → `.vibing/plugins/*/` → `agent.plugins.extra`, because the **earlier
  `--plugin-dir` flag wins**.
- **A directory the CLI declines is silently ignored**, so `plugin_dirs` reads each candidate's
  `.claude-plugin/plugin.json` itself and warns about the ones it drops.
- **`.vibing/plugins/` is read by default, and that is a security decision**: a plugin may declare
  `mcpServers`. `agent.plugins.project_dir = false` is the opt-out.
- **`:VibingReloadCommands` clears `plugin_dirs` first**, before the provider caches — both
  re-resolve from it.
- **Not passed on the lightweight path**, per `core/types.lua`.
- **`TERMINAL_ONLY_COMMANDS` is a denylist, not an allowlist**: built-in skills live inside the
  binary, and a stale allowlist would hide a new one.
- **Codex loads the same list, in two halves.** Codex 0.153 has no per-run plugin flag, so
  `adapter/modules/codex_plugin_config.lua` turns each plugin's `mcpServers` into
  `-c mcp_servers.<name>.*` overrides (`default_tools_approval_mode="approve"`, or headless exec
  cancels every call) and lists its `skills/` in `-c developer_instructions`. `agents/` does not
  travel. Server names must be bare TOML keys — the `-c` key path is never unquoted.
  `handbook/architecture/plugin-and-commands.md` → "Codex".
- **`setup()` runs on the user's startup path**, so synchronous I/O there is the cost that
  matters. Custom slash commands are scanned on first use, with the already-loaded guard set
  **before** the scan.

Measurements: `handbook/architecture/plugin-and-commands.md`.

## Module Structure

Layered `domain` / `application` / `infrastructure` / `presentation`, not the flat `actions/` +
`ui/` layout used before v4. The per-directory listing, the key entry points, and what a new
backend still has to write (`new()` and `stream()`, and why `stream()` stayed per-adapter) are in
`handbook/architecture/module-map.md`.

## Session Persistence

Chat files are Markdown with YAML frontmatter (`session_id`, `working_dir`, `model`, `effort`,
`permission_mode`, `permissions_allow` / `_deny`, `language`, `orchestrated` / `orchestrated_by`).
The full field list is `doc/vibing.txt` → "CHAT FILE FORMAT".

- **The key is singular `permission_mode`.** The legacy plural `permissions_mode` is migrated on
  parse (`infrastructure/storage/frontmatter.lua`) so old files keep working, but it is no longer
  completed and must not be written.
- **`effort` is backend-neutral frontmatter.** Claude and Grok receive `--effort`; Codex receives
  `-c model_reasoning_effort=...`. New chats write `effort: default`; that reserved value (and a
  missing field in old chats) passes no override, so the CLI/model applies the same default it did
  before this setting existed. An unrecognised level is dropped with a warning, because some CLIs
  accept unknown levels silently and ignore them.
- **`Git.resolve_working_dir` bounds `working_dir` to the git root.** A value resolving outside is
  warned about once and treated as unset (`nil` already means "no chat-specific cwd" at every call
  site), which is what lets `create_chat.lua` reject an out-of-bounds request outright.
  `handbook/architecture/session-persistence.md`.
- **Lightweight calls** (title generation, `/summarize`, `:VibingSummarize`, daily summary) owe
  the obligation stated in `core/types.lua` — no tools, no project config, no user MCP servers, no
  hooks, `utility_model` — not any one backend's mechanism. Grok is the one backend that cannot
  keep the whole bargain. `handbook/architecture/lightweight-calls.md`.

## Per-Request Diffs

Each turn's `### Modified Files` and its `.vibing/patches/*.patch` come from **two git tree
snapshots of the working tree** (`core/utils/git_snapshot.lua`), so a change made by `sed -i`, `mv`
or a formatter run through Bash still shows up (#625).

- **The user's index is never touched.** `git add -A` runs against a copy handed over as
  `GIT_INDEX_FILE`.
- **The baseline is lazy**, taken at the PreToolUse hook for the first tool that could write. The
  trigger is an **exclusion** list, not an allow list: a tool whose name says nothing about its
  behaviour has to count as a writer.
- **`.vibing/` is excluded by pathspec on the diff calls, and only conditionally on `git add -A`**
  — `git add` exits 1 when a pathspec explicitly names an ignored path, including a _negative_
  one, which silently disabled the whole mechanism until #664. The same exclusion must also be
  applied when `extra_paths` is merged into either diff implementation, or tool events add the
  directory back after git excluded it. Test the path relative to the current worktree root — a
  worktree itself normally lives below an outer `.vibing/worktrees/`.
- **The git calls block the main loop** (`vim.system():wait()`): 20ms per `git add -A` on a 9k-file
  tree, 63ms on an 80k one.
- **`request_diff.lua` stays as the fallback**, and a turn where both come up empty **warns**
  rather than rendering as a turn that changed nothing.

`handbook/architecture/per-request-diffs.md`.

## Processes and Turns

A CLI process and one request/response exchange are **two things with two ids** (#775/#776), both
minted by `core/utils/identity.lua`. `handle_id` meant both and is gone from `lua/`; it must not
come back. `handbook/architecture/processes-and-turns.md`.

- **Ask which id a consumer means before keying anything on it.** Process-keyed: the adapter's
  `_processes` table and everything `kill_tree` reaches, the SessionManager (`--resume` names a
  conversation the _process_ holds open), the child's `VIBING_PROCESS_ID`,
  `ChatBuffer._current_process_id`. Turn-keyed: both diff baselines and
  `refs/worktree/vibing/<turn_id>`, the `.vibing/patches/*.patch` suffix, `response._turn_id` and
  the chunk staleness filters, the parked rate-limit failure, `permission.lua`'s
  `active_opts_by_turn`.
- **Nothing parses an id to learn its kind** — both minters emit the same shape on purpose. Both
  ids must survive `[^A-Za-z0-9_]` deletion unchanged: `bin/hooks/*.sh` interpolates the process id
  after exactly that substitution, and the turn id names a git ref and a patch filename.
  `identity_spec.lua` reads the character class back out of the shell scripts, because `test:lua`
  never runs them.
- **The hook can only ever name a process**, because `VIBING_PROCESS_ID` is fixed at spawn and an
  environment variable cannot carry a per-turn value to a process that outlives the turn. The turn
  is never on the wire: `rpc/hook_scope.lua` resolves it in-editor, and is the **one** place that
  resolution happens — it was previously derived three times per call under two policies, which
  disagreed. An id that is **present but unmatched** resolves to `nil`, never to the sole
  registered entry; that fallback applied another chat's `allow` / `deny` / `:once` lists to a late
  hook, the #667 failure through a door #667 did not close.
- **Two registries, cut where the ids are cut.** `process_registry.lua` holds the `--resume`
  session, the chat, the adapter and `active_turn_id`; `turn_registry.lua`'s entries hold a
  _reference_ to their process entry rather than a copy, so `adapter` / `chat_bufnr` / `session_id`
  have one home and cannot drift. `turn_registry` requires `process_registry`, never the reverse.
- **"Who holds the session" is a process question; "who is writing in this worktree" is a turn
  question.** `find_other_holding_session` asked of turns would let a second process attach to a
  transcript the moment the first went idle (the #756 corruption), since a resident process keeps
  its `--resume` between turns. `find_other_writing_in` asked of processes would make every chat in
  one repository overlap every other one permanently, retiring the #625 snapshot for good.
- **`turn_registry.get` has no nil fallback**; a caller with no id asks `sole_open()` and says so.
  Inheriting the fallback reports every stale baseline as still open whenever one turn is running,
  which stops `git_snapshot`'s TTL sweep and lets `refs/worktree/vibing/` grow without bound.
- **A hook whose turn cannot be resolved takes no baseline at all.** One filed under the raw id is
  never cleared, because `clear()` is only reached through a response.

## The Duplex Transport

One resident `claude` process per chat, serving many turns over an open stdin. **Opt-in, claude
only, default off** — `backends.claude.process = "duplex"` or a chat's own `process:` frontmatter.
`process_model.lua` is the one place the exclusions live: a lightweight call, a subagent chat and
every backend other than claude can never use it, whatever the configuration says.
`handbook/architecture/duplex-transport.md`.

- **`descriptor.process` is a ceiling, not a default.** A descriptor that does not declare `duplex`
  cannot be configured into it.
- **The reuse key is the argv, and it is built with no session id.** `permission_mode` comes from
  frontmatter, changes between turns and changes the argv, and a live process cannot be re-flagged.
  Including the session makes the key differ by construction on every chat's second turn — every
  chat restarts its process every time and the measured win is exactly zero, while the code looks
  correct.
- **A dying process is identified, never looked up.** stdout, stderr and exit reach a _process_,
  and `jobstop` only asks: the dying process's callbacks land **after** its replacement is
  registered under the same chat key. So each callback carries its own record and asks _am I still
  the current process_, never _what is current_.
- **A process that still has `_turn` set is not reusable**; `duplex_pool.acquire` replaces it.
  `ChatBuffer:send_message` guards only `_is_sending` and relied on `cancel_request` closing the
  previous turn synchronously, which is true of a kill and not of an interrupt.
- **Every reclaim route announces itself.** `VimLeavePre`, the idle timer, an argv change and the
  CLI dying are four routes and only the last arrives as `on_exit`, so `duplex_pool.forget` carries
  the notification itself, once per process — or `cleanup_stale_sessions` reads a dead handle as
  still running and keeps its session entry alive forever.
- **A turn ends on the `result` event, not on process exit.** `result` always emits `turn_end`,
  _after_ the `error` arm it may also emit, so a turn the CLI declared failed has reached
  `resultErrors` first. The oneshot path sets no `onTurnEnd` and drops the event. The event context
  is per turn; the decoder's parse state is per process.

## Concurrent Execution, Fork and Subagent Chat

Each chat buffer maintains its own session ID; processes and turns are keyed by the two ids above
(`hrtime + random`, hex — see "Processes and Turns").

- **Creating a directory two processes could both create is a shared-state operation.**
  `vim.fn.mkdir(path, "p")` is not atomic and raises `E739` when another process wins the race —
  9 failures in 200 concurrent calls. Every such creation goes through `core/utils/fs.lua`'s
  `ensure_dir`. `tests/lua/mkdir_call_sites_spec.lua` **fails the build** on a direct
  `vim.fn.mkdir` anywhere in `lua/`, and on one in `tests/` whose path is not provably rooted at
  `vim.fn.tempname()` — plenary runs one child Neovim per spec file, so a fixed path under the
  cwd or `$HOME` is shared between them, and it was a spec that flaked (#576). Anything the
  analysis cannot prove is reported; `-- mkdir-ok: <reason>` waives the line that has no choice.
- **A fork inherits the source's `session_id`** and marks itself with `forked_from`;
  `opts._is_fork` makes the command builder emit `--fork-session`.
- **A subagent chat shares the parent's `session_id` permanently and must never fork** —
  `--fork-session` makes `SendMessage` fail with `No transcript found for agent ID`. Two buffers
  therefore resume one session, so `send_message.lua` hard-refuses a send while another buffer's
  stream holds it.

`handbook/architecture/chat-lineage.md`.

## Multi-Agent Orchestration

One chat can create and drive others: `nvim_chat_create` (MCP) → `rpc/handlers/chat.lua` →
`application/chat/use_cases/create_chat.lua`. The workflow is the bundled
`claude-plugin/skills/vibing-orchestrate/SKILL.md`; there is no command and no scheduler.

- **The chat file path is the identifier; a bufnr is a per-session resolution of it.**
  `nvim_chat_send_message` and `nvim_get_buffer` take `file_path` or `bufnr` and **refuse a call
  that passes both**. `from_bufnr` stays a bufnr, since it names the calling chat.
- **The relationship is recorded in frontmatter, not in the transcript** — `orchestrated` /
  `orchestrated_by`, kept in step across renames by `link/orchestration_chat_scanner.lua`.
- **An `orchestrated` element is `<path>` or `<path>|<task>` (#696), encoded/decoded only through
  `orchestrated_entry.lua`.** The task an orchestrator gave a chat lives there — on the
  orchestrator's own entry — and nowhere on the driven chat's own frontmatter; `orchestrated_by`
  never carries the suffix. Comparing or replacing an `orchestrated` item as a bare string instead
  of going through `OrchestratedEntry.find`/`encode` silently breaks on any entry that has a task.
- **Completion detection is a status field, not a text heuristic**, and `idle` means "no request
  in flight", **not** "succeeded".
- **Completion is pushed, not polled, and the send is the subscription.** The CLI process dies
  when its turn ends, so the only way to deliver anything to a chat is to start a new turn on it.
- **Reporting is the worker's job; the notification is a watchdog.** `agent.chat_notifications`
  gates only the watchdog — a stop the chat cannot leave on its own (`asked_question`,
  `waiting_approval`, `error`) is delivered whatever the setting is.
- **The report protocol is injected, not left to the brief or to skill auto-trigger** (#706). A
  chat with `orchestrated_by` gets the orchestrator's `file_path` and the report protocol appended
  to its system prompt on every turn (`cli_command_builder.lua`), pointing at the
  `claude-plugin/skills/vibing-worker/SKILL.md` skill for the rest. Skill discovery by description
  match is probabilistic, so this line — not the orchestrator's brief text — is the one place a
  worker is guaranteed to be told where and how to report.
- **A worker's tool-approval prompt is the user's to clear unless the user says otherwise**
  (`agent.orchestration.delegated_approval`, default `false`).
- **A message delivered from another chat gets its own section kind** — `## Request`, `## Report`
  or `## Notice`. `extract_role` still answers `user` for all three.

The notification state machine, the queue, the round-trip budget and the tree operations:
`handbook/architecture/orchestration.md`.

## Git Worktree Integration

Worktrees are plain `git worktree add -b <branch> .vibing/worktrees/<branch>/`, removed with
`git worktree remove`; a worktree's existence on disk is its entire state. There is no lifecycle
script and no metadata file. The chat's `working_dir` frontmatter keeps a conversation attached to
its worktree across turns. The workflow is the bundled `vibing-worktree-*` skills
(`claude-plugin/skills/`), driven by natural language.
