# Chat Lineage: Concurrency, Forks and Subagent Chats

Detail behind `.claude/rules/architecture.md` → "Concurrent Execution Support", "Chat Fork" and
"Subagent Chat". These three share one substrate: every chat buffer owns its own session id and
handle id, and what varies is whether a new chat diverges from that session (a fork), shares it
permanently (a subagent chat), or is simply independent.

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

See `handbook/adr/002-concurrent-execution-support.md` for architectural details.

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
