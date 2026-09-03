# Features

## Usage Limit: Auto-Resume and Scheduled Requests

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
timestamp. Concurrently parked chats all fire at once by design. See `handbook/configuration.md` →
"Auto-Resume on Usage Limit".

**Implementation:** `application/chat/auto_resume.lua` (scheduler),
`infrastructure/storage/pending_resume.lua` (persistence),
`infrastructure/rpc/handlers/rate_limit.lua` (StopFailure receiver), `bin/hooks/stop-failure.sh`.

A pending entry also has a `kind`. `auto_resume` (the default, and what a missing `kind` reads as)
sends the configured continuation prompt above. `scheduled` sends the chat's own unsent `## User`
body instead — the body is never copied into the pending-resume store, so it stays visible and
editable in the buffer while parked.

Scheduled requests come from three places: `:VibingSchedule [when]`, which works with no usage
limit on record at all as long as `when` is given (the no-argument form is the one that needs
`.vibing/limit-state.json`); a `<CR>` that lands while that file records a still-active limit
(excluding slash commands and a reply to a pending approval prompt, which always send
immediately); and a turn the limit actually rejected, whose message is written back into a fresh
unsent section instead of being discarded. The limit-aware `<CR>` and the rejected-turn
re-schedule are both governed by `agent.scheduled_requests.enabled` (default `true`);
`:VibingSchedule` is not, since the user armed it by hand.

`:VibingSchedule` and the limit-aware `<CR>` both save the chat file before arming the timer, but
differ on a save failure: `:VibingSchedule` refuses to schedule and nothing is sent — the message
stays unsent in the buffer for the user to retry; the `<CR>` interception instead fails open and
sends the message immediately, on the reasoning that a normal send is safer than silently sitting
on a message the user just tried to send. The rejected-turn path writes the text back into the
buffer the same way but leaves the actual save to whatever happens next (e.g. the buffer being
saved for an unrelated reason), rather than saving synchronously itself.

`agent.scheduled_requests.max_retries` (default 3) bounds the fire → rejected → re-schedule loop.
Because the budget check is applied to the already-incremented retry count, the default only
permits **2** re-schedules after the first rejection. The next rejection falls through to
`auto_resume.on_rate_limited`, which re-checks the _same_ stored `retry_count` (already at 2)
against `auto_resume_on_limit.max_retries` — with both features at their defaults
(`scheduled_requests.max_retries = 3`, `auto_resume_on_limit.max_retries = 1`) that budget is
already spent, so the request is simply dropped. The fixed continuation prompt only fires if the
user has raised `auto_resume_on_limit.max_retries` above what the scheduled retries already
consumed.

`.vibing/limit-state.json` holds one record per project — the last observed reset time — and is
what lets a chat that never hit the limit itself still schedule instead of send. It is written
only when the payload carried a reset timestamp, and cleared on any successful response, so a
limit that lifts early is forgotten as soon as one request gets through. `:VibingCancelResume` also
clears this record (in addition to cancelling the entry), so "send now" — cancel, then `<CR>` —
actually sends instead of being re-parked by a stale record; if the limit is genuinely still in
force, the next rejected response re-records it.

**The record names the backend that hit the limit, and every reader is scoped to it.** The store
is per project but a limit belongs to one provider's plan, so an unscoped record parked codex
chats behind a claude limit — for the whole reset window, with no way to converse — and let a
successful codex turn clear the claude record out from under the chats waiting on it.
The two sides name the backend differently, and the difference is deliberate. **Writing** the
record — and clearing it on a successful turn — asks `factory.agent_id(adapter)` about the adapter
that actually ran, because "who was rejected" is a fact about the process, not about frontmatter a
user can edit while the turn is in flight. **Reading** it before a request exists
(`<CR>`, `:VibingSchedule`, `:VibingCancelResume`) has no adapter yet, so it predicts one with
`Modes.resolve_agent` (frontmatter `agent` > `config.adapter` > claude) — the same precedence
`send_message._resolve_adapter` applies a moment later.

A record with no `agent` field reads as claude's, since claude is the only backend that reports a
rate limit (`claude_cli.lua`) and so the only one that could have written one.
`:VibingCancelResume all` is the one unscoped clear left: it has no chat in hand, and "forget
everything" is the user saying so by hand.

**Implementation:** `infrastructure/storage/limit_state.lua` (project limit record),
`core/utils/when.lua` (time spec parser), plus the `kind` dispatch in
`application/chat/auto_resume.lua`.

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

`claude-plugin/skills/vibing-code-tour/SKILL.md` turns "explain how X works" into a walkthrough
the editor performs: each stop is a real file opened at a real line (`nvim_win_open_file` +
`nvim_set_cursor`), and the whole route is left in the quickfix list so the user can replay it
with `:cnext`/`:cprev` afterwards.

Both calls take the target window explicitly, and the skill insists on it: `nvim_win_open_file`
restores focus before returning, so the window showing the file is never the current one. A
`nvim_set_cursor` without `winnr` moves the chat's cursor instead — and succeeds, so the tour
looks like it is working while the code window never moves.

The quickfix half is the MCP tool `nvim_set_qflist`
(`claude-plugin/mcp-server/src/tools/qflist.ts` → `infrastructure/rpc/handlers/qflist.lua`). It
always pushes a **new** list
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

## Debugger Analysis (nvim-dap)

When the debugger is stopped, the agent can look at the actual runtime state instead of reasoning
about the source: `nvim_dap_get_state`, `nvim_dap_get_stack_trace`, `nvim_dap_get_variables`,
`nvim_dap_set_breakpoint`, `nvim_dap_evaluate` (`infrastructure/rpc/handlers/dap.lua`).

nvim-dap is an **optional** dependency. Every entry point reports "nvim-dap is not installed" or
"no debug session is running" rather than erroring, so the agent gets an explanation it can act on
— which is also why `nvim_dap_get_state` exists and its description tells the model to call it
first.

DAP requests are callback-based while RPC handlers return a value, so each request is awaited with
`vim.wait`. That is only safe because the RPC server already dispatches handlers inside
`vim.schedule`: we are on the main loop, and `vim.wait` keeps processing events, which is what lets
the adapter's reply arrive at all.

`vim.wait` does still block the editor, though, so a handler that issues several requests spends
**one shared budget** across them (`deadline()` in `dap.lua`). `dap_get_variables` asks for scopes
and then for the variables of each scope; with a per-request timeout a slow adapter and a frame
with four scopes would freeze Neovim for 25 seconds on a single tool call.

`dap_get_variables` expands only the top level of each scope. A deep object graph would flood the
chat, and the agent can follow up with `dap_evaluate` on whatever it actually wants. Note that
`dap_evaluate` runs **in the debuggee** — an expression with side effects will have them, and the
tool description says so.

`:VibingDebugAnalyze` and `:VibingDebugHelp` send a request to the chat. They send only the
request, never a state dump: the agent fetches whatever depth it needs through the tools above.
`config.dap.enabled` additionally subscribes to nvim-dap's stopped event; `auto_analyze_on_error`
(default `true`) fires on exceptions, `auto_analyze_on_breakpoint` (default `false`) on ordinary
breakpoints — a breakpoint is something the user placed on purpose, and spending tokens unattended
every time one is hit gets in the way. The whole feature is off until `dap.enabled` is set.

**Implementation:** `application/debug/analyze.lua` (commands + stopped-event listener),
`infrastructure/rpc/handlers/dap.lua`, `claude-plugin/mcp-server/src/{tools,handlers}/dap.ts`.

## Message Timestamps

Chat messages include timestamps in their headers (`## 2025-12-28 14:30:00 User`) for chronology
and search — `/2025-12-28` in Neovim, or `grep "## 2025-12-28" .vibing/chat/*.md` across chat
files. Legacy headers without timestamps (`## User`, `## Assistant`) remain fully supported. User
timestamps are recorded when the message is sent (`<CR>`); Assistant timestamps are recorded when
the response begins (`on_done` callback). Timestamps use the local system timezone (Lua's
`os.date()`).

A message another chat delivered gets its own section kind rather than a `## User`, so a
transcript says who wrote what:

```markdown
## Request <!-- 2026-09-02 08:13:11 from .vibing/chat/orchestrator.md -->

## Report <!-- 2026-09-02 08:14:07 from .vibing/chat/worker-a.md -->

## Notice <!-- 2026-09-02 08:14:16 -->
```

`Request` is a dispatch, `Report` a reply or a completion report, `Notice` a watchdog wake-up
vibing.nvim generated itself. Which of the first two applies is decided by
`orchestration_link.direction`, not guessed from the text. The grammar is
`## <Kind> <!-- <unsent|timestamp>[ from <path>] -->` and lives only in `timestamp.lua`;
`parse_header` is what every reader goes through. Why `extract_role` still answers `user` for all
three: `handbook/architecture/orchestration.md` → "Delivered sections".

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
```

That is the whole of it — the question text and the options, appended under the unsent `## User`
header. There is no trailing "press `<CR>` to send" line; only the _approval_ UI has one
(`renderer.lua`). This example used to include one, and `tests/e2e/ask_user_question_spec.lua` was
written against the documentation rather than the renderer, so it waited forever for a string
nothing emits.

Single-select questions render as a numbered list (`1. 2. 3.`); multi-select questions render as a
bullet list (`- - -`). The user deletes unwanted options with standard Vim commands (`dd`, etc.)
and sends the remainder with `<CR>`.

**Implementation:** the primary path is vibing.nvim's own MCP tool
`mcp__vibing-nvim__nvim_ask_user_question` (`claude-plugin/mcp-server/src/tools/chat.ts`), which
the CLI's system prompt instructs the model to use instead of the native tool. Its handler calls
`M.ask_user_question()` in `infrastructure/rpc/handlers/permission.lua`, which cancels the
in-flight turn and renders the choice list via `on_insert_choices`. Because the turn is killed,
the tool's return value never reaches the model — the user's answer arrives as the next `--resume`d
turn's user message, so no Promise/state handling is required.

**The choice list is only staged, so the staging has to be synchronous.** `on_insert_choices`
writes `_pending_choices` and nothing else; the one thing that renders it is `add_user_section()`
at the end of `_handle_response`. But `cancel()` runs the adapter's wrapped `on_done`, and that is
what queues the completion — so a staging deferred by its own `vim.schedule` lands one tick too
late, the completion consumes a nil, and the turn ends cut short with nothing in the buffer to
answer (#649). Neither this callback nor `on_approval_required` may add an inner `vim.schedule`:
both are already on the main thread when `permission.lua` calls them. `on_approval_required` had
always obeyed that rule; `on_insert_choices` was the one that did not.

Rendering from `insert_choices` itself is not the alternative — `### Modified Files` and the patch
comment are appended _before_ the User section, so the diff would land underneath the choices.

Native `AskUserQuestion` is unavailable in headless `claude -p` mode and is opaque to vibing.nvim,
so the PreToolUse hook intercepts and denies it, rendering the same UI as a fallback.

**Codex backend: not wired.** `codex_cli.lua` deliberately omits `chat_bufnr` when registering
with `ActiveStreamRegistry`, and the developer message tells the model not to call the tool. The
two things that originally made this impossible (#532) are gone as of codex 0.153, which is worth
recording so the next reader does not rediscover them:

- Codex now takes a system prompt seam: `-c developer_instructions` becomes the first `developer`
  message. Context and language are still prepended to the user prompt.
- Headless `codex exec` still auto-cancels an MCP call at its own approval prompt — stdin is
  closed, so EOF reads as a denial ([openai/codex#24135][codex-24135]) — but
  `-c mcp_servers.<name>.default_tools_approval_mode="approve"` is a per-server answer to it, and
  is how the bundled server reaches codex at all (`architecture.md` → "Plugin Loading").

What remains untested is the UI itself on this backend, so the route stays unwired rather than
registered and looking like it works. What does work on Codex is the ordinary tool-approval flow
(the `ask` permission list): it routes on `handle_id`, not `chat_bufnr`.

[codex-24135]: https://github.com/openai/codex/issues/24135
