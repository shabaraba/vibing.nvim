# Features

## Auto-Resume on Usage Limit

When a turn is rejected because the plan's usage limit is exhausted, vibing.nvim can park the chat
and send a single continuation message once the limit resets. Opt-in via
`agent.auto_resume_on_limit.enabled` (default `false` — it spends tokens unattended).

Detection merges three signals in `lua/vibing/core/utils/rate_limit.lua`: the CLI's
`rate_limit_event` stream line (the **only** source of `resetsAt`), the `StopFailure` hook filtered
to `error_type = rate_limit` (confirms the turn died, no timestamp), and the error text as a
fallback. None of these payload shapes is officially documented, so every field is optional and a
schema change degrades the feature instead of breaking the stream.

Pending resumes persist to `.vibing/pending-resume.json` and are re-armed on `setup()`, since a
five-hour reset usually outlives the Neovim session. Safeguards: `max_retries` (default 1) per
limit hit, never overwriting an unsent `## User` message, and an 8-day sanity ceiling on the reset
timestamp. Concurrently parked chats all fire at once by design. See `docs/configuration.md` →
"Auto-Resume on Usage Limit".

**Implementation:** `application/chat/auto_resume.lua` (scheduler),
`infrastructure/storage/pending_resume.lua` (persistence),
`infrastructure/rpc/handlers/rate_limit.lua` (StopFailure receiver), `bin/hooks/stop-failure.sh`.

## Subagent Output Visibility

The Claude CLI hides everything a subagent says unless it is launched with
`--forward-subagent-text`; without the flag a `Task`/`Agent` call shows only its header and final
result. `agent.subagent.enabled` (default `false`) opts in, and
`modules/subagent_display.lua` renders the forwarded text under the tool header behind a `│` rail
(`show_prefix` adds a `[<subagent_type>]` label per line).

The shape of the stream is what makes this simple, and was verified against the CLI rather than
assumed: subagent contributions arrive as **complete `assistant`/`user` events with a top-level
`parent_tool_use_id`**, never as `stream_event` deltas. So the parent's own streaming text is
untouched, and `cli_event_processor.lua` can buffer per `tool_use_id` in `context._subagent_text`
and flush at `emit_tool_result` — which is what keeps parallel subagents from interleaving.

**The trap:** top-level events carry `"parent_tool_use_id": null`, which `vim.json.decode` turns
into `vim.NIL` — truthy in Lua. Testing the field directly routes every ordinary assistant message
into the subagent buffer and silently stops all tool results from rendering. Go through the
`parent_tool_use_id(msg)` helper, which requires a non-empty string.

Only the subagent's assistant text is surfaced; the prompt echo, thinking blocks, and its nested
tool results stay hidden. `tests/fixtures/subagent_stream.jsonl` is a real captured stream used to
replay the whole path in `cli_event_processor_subagent_spec.lua`.

## Code Tour

`skills/vibing-code-tour/SKILL.md` turns "explain how X works" into a walkthrough the editor
performs: each stop is a real file opened at a real line (`nvim_win_open_file` +
`nvim_set_cursor`), and the whole route is left in the quickfix list so the user can replay it
with `:cnext`/`:cprev` afterwards.

The quickfix half is the MCP tool `nvim_set_qflist` (`mcp-server/src/tools/qflist.ts` →
`infrastructure/rpc/handlers/qflist.lua`). It always pushes a **new** list
(`vim.fn.setqflist({}, " ", ...)`), so whatever the user had in quickfix stays reachable under
`:colder` — which is also why the skill must call it exactly once per tour, or `:cnext` walks a
different list than the one being narrated. `open: true` opens the quickfix window but restores
focus, matching `win_open_file`. `col` is 1-based here (native quickfix), unlike the 0-based `col`
everywhere else in this tool surface.

A stop naming a file that does not exist rejects the whole call: the tool result does reach the
model, so a hard error is actionable, while a silently shortened tour is not. That existence check
is Lua-side, not in the MCP server, because relative paths resolve against the target instance's
cwd — often a worktree the server process knows nothing about.

The pacing question in the skill inherits AskUserQuestion's turn-killing behavior (below), so the
skill is instructed to write the tour's position and remaining stops into its chat message before
every ask — the transcript is the only place that state survives.

## Message Timestamps

Chat messages include timestamps in their headers (`## 2025-12-28 14:30:00 User`) for chronology
and search — `/2025-12-28` in Neovim, or `grep "## 2025-12-28" .vibing/chat/*.md` across chat
files. Legacy headers without timestamps (`## User`, `## Assistant`) remain fully supported. User
timestamps are recorded when the message is sent (`<CR>`); Assistant timestamps are recorded when
the response begins (`on_done` callback). Timestamps use the local system timezone (Lua's
`os.date()`).

Implemented in `lua/vibing/utils/timestamp.lua`: `create_header(role, timestamp)`,
`extract_role(line)`, `has_timestamp(line)`, `extract_timestamp(line)`, `is_header(line)`.

## AskUserQuestion Support

Multiple-choice questions render as plain markdown in the chat buffer instead of a native prompt,
so the user can answer with ordinary Vim editing:

```markdown
Which database should we use?

1. PostgreSQL
2. MySQL
3. SQLite

Please answer the question and press `<CR>` to send.
```

Single-select questions render as a numbered list (`1. 2. 3.`); multi-select questions render as a
bullet list (`- - -`). The user deletes unwanted options with standard Vim commands (`dd`, etc.)
and sends the remainder with `<CR>`.

**Implementation:** the primary path is vibing.nvim's own MCP tool
`mcp__vibing-nvim__nvim_ask_user_question` (`mcp-server/src/tools/chat.ts`), which the CLI's
system prompt instructs the model to use instead of the native tool. Its handler calls
`M.ask_user_question()` in `infrastructure/rpc/handlers/permission.lua`, which cancels the
in-flight turn and renders the choice list via `on_insert_choices`. Because the turn is killed,
the tool's return value never reaches the model — the user's answer arrives as the next `--resume`d
turn's user message, so no Promise/state handling is required.

Native `AskUserQuestion` is unavailable in headless `claude -p` mode and is opaque to vibing.nvim,
so the PreToolUse hook intercepts and denies it, rendering the same UI as a fallback.

**Codex backend: not available.** Codex sessions cannot reach this UI, so `codex_cli.lua`
deliberately omits `chat_bufnr` when registering with `ActiveStreamRegistry`. Two things block it,
and neither is fixable from this side:

- Codex takes no system prompt (context and language are prepended to the user prompt instead), so
  there is no place to hand the model the `chat_bufnr` the tool needs.
- Registering the MCP server per run via `-c mcp_servers.*` would not help. Headless `codex exec`
  auto-cancels MCP tool calls at the approval prompt — stdin is closed, so EOF reads as a denial —
  unless it runs with `--dangerously-bypass-approvals-and-sandbox`, which vibing.nvim only passes
  in `bypassPermissions` mode. See [openai/codex#24135][codex-24135].

What still works on Codex is the ordinary tool-approval flow (the `ask` permission list): it routes
on `handle_id`, not `chat_bufnr`. Only the question-list UI is missing. Revisit if the upstream
issue is resolved.

[codex-24135]: https://github.com/openai/codex/issues/24135
