# Chat UI: Subagent Output, Timestamps and AskUserQuestion

Moved out of `.claude/rules/features.md`. The always-loaded rule for each of these is one line in
that file; the reasoning and the traps are here.

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
tool results stay hidden. `tests/fixtures/streams/claude/subagent_forwarding.jsonl` is a real captured stream used to
replay the whole path in `cli_event_processor_subagent_spec.lua`.

## Background Subagents

A subagent launched with `run_in_background` outlives the turn that launched it, and for a long
time a vibing chat looked like it had simply stopped when one was running.

**It had not, and neither had the CLI.** Measured against claude 2.1.273, `claude -p` holds its
process open for a background subagent, emits `system/task_notification` when it finishes, and
**opens a new turn by itself** — no input, no prompting, nothing for vibing to schedule. Captured
sequence from one run:

```text
assistant  text "launched"          <- the launching turn ends here
system/task_notification            <- the subagent finished
system/init                         <- the CLI opens a second turn on its own
assistant  text "…完了しました。応答は `PONG` です。"
result  num_turns=2                 <- turn 1
result  num_turns=1                 <- turn 2
```

Two things in that trace are easy to get wrong.

**One process emits one `result` per turn.** Measured at 2 and 5 in single `claude -p` runs. The
oneshot transport therefore cannot treat the first `result` as the end of anything: doing so
truncates every notification-driven turn after it, together with the tool calls in them. A real
session lost three turns and a `Read`/`Write`/`Edit` sequence this way — the edits happened, the
user never saw them, and no `### Modified Files` was written.

**Background Bash and background subagents have opposite exit behaviour.** The docs
(`code.claude.com/docs/en/headless`) kill a backgrounded shell about five seconds after the final
result, but hold the process open for a subagent. Do not generalise from one to the other.

The wait is bounded by a **ten-minute idle ceiling**, past which Claude Code "stops whatever is
still running and drops its partial result". That suits a one-shot CI invocation and not a chat,
so `backends.claude.background_wait_sec` (default 3600, `0` for no limit) is passed as
`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`.

### What the stream carries

`system/task_started` announces a launch and is tracked only when `is_backgrounded` is set — a
foreground subagent closes inside its own turn as a `tool_result`, so recording it would leave it
unreported forever. It also carries `subagent_type` and `description`.

`system/task_notification` is the completion:

```json
{ "subtype": "task_notification", "task_id": "a800809d218e08d3b",
  "tool_use_id": "toolu_01K3di…", "status": "completed",
  "output_file": "…/tasks/a800809d218e08d3b.output", "summary": "PONG",
  "usage": { "total_tokens": 19469, "tool_uses": 0, "duration_ms": 1610 } }
```

`task_id` is the same identifier `subagent_marker.lua` scrapes out of the tool result as `agentId`,
and the same one naming `subagents/agent-<id>.jsonl`. One id, three places.

Only the completion is drawn (`background_tasks.format_done`), and only its metadata. The launch is
already on screen as the `Agent(...)` tool line, and the subagent's answer reaches the model through
the notification — printing the summary here would show every report twice.

### Recovering a dropped notification

Upstream drops a notification that arrives while the parent is mid-turn
(anthropics/claude-code#87675: 19 subagents launched, 15 notified, the parent idle for hours). That
one is not vibing's to fix, so at the end of the turn the started-minus-notified set is read back
out of each subagent's own transcript and delivered as a `## Notice`.

This path must do nothing on the ordinary route, and it reports only what it actually found: a
notice saying a subagent finished with no content attached is worse than staying quiet. The
transcript location is derived rather than remembered, because a task that was never notified never
told us its `output_file`.

## Message Timestamps

Chat messages include timestamps in their headers (`## User <!-- 2025-12-28 14:30:00 -->`) for
chronology and search — `/2025-12-28` in Neovim, or `grep "<!-- 2025-12-28" .vibing/chat/*.md`
across chat files. Legacy headers without timestamps (`## User`, `## Assistant`) are still
parsed, via `LEGACY_HEADER_PATTERN`. User
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

Implemented in `lua/vibing/core/utils/timestamp.lua`: `create_header(role, timestamp)`,
`extract_role(line)`, `has_timestamp(line)`, `extract_timestamp(line)`, `is_header(line)`.

## Where a Rendered Tool Call Ends

`event_renderer` writes `<marker> <Name>(<input summary>)`, and for `Bash` the summary is
`tool_input.command` verbatim — so one call can be a whole script, blank lines and all. Where it
ends decides what highlights as a tool call, what folds as one, and what `chat_excerpt` drops
before a chat reaches title generation or `/summarize`.

**The renderer marks the lines it writes, and that is the answer wherever it is present.**
`event_renderer`'s `mark_continuations` puts the indent a result's continuation lines already use in
front of every line of an argument that spans more than one. It is five spaces, and the two Lua
sides take it from `tool_display.CONTINUATION_INDENT` — the module that was already writing it for a
result — rather than each declaring it. The side writing the
closing `)` is the side that knows where the call ends, so it says so instead of leaving it to be
worked out. Two things that cannot be worked out become free: a script line reading exactly
`## Assistant` (a marked line starts with a space, so it can never look like a chat boundary), and
a header line that closes its own parenthesis (`Bash(case x in a) …`, which is indistinguishable
from a call that fits on one line).

**Chats written before that still have to be read, and there the parentheses are counted.** The
rule has three parts, all of them arrived at from real chats: quoted spans and escaped characters
do not count (`Bash(echo ')' && git rebase ...)` closed on the quoted one and left the rebase
behind as prose), a heredoc body is data rather than shell code (a Python triple-quoted string
inside one lost the end of the block and left tens of thousands of characters of script in the
excerpt), and past 500 lines the whole thing is given up on. The floor when it is given up on is
the oldest rule, "the first line whose last character is `)`" — which on its own cut a script at
its first `foo(x)` and left everything after it unfolded and unhighlighted, and, when nothing
closed at all, read on through the next `## Assistant` and took the chat boundary with it. A chat
boundary now stops the search, the same way it stops an unfinished code fence.

The marking is only believed when the renderer's own `)` ends the run. An indented line in an
unmarked chat is indistinguishable from a marked one, and without that condition a call like
`Bash(if true; then` / `␣␣␣␣␣echo hi` / `fi)` would stop one line early on every chat written
before this. Which means a run that is _not_ believed has to have been counted the whole way as if
it were ordinary lines — including its heredoc bodies. A chat whose heredoc body happens to be
indented five spaces looks entirely marked and closes nothing, and counting those lines as shell
code instead of as data ends the call inside the heredoc.

There are two implementations of the counting because the grammar's is in C, inside
`tree-sitter-vibing/src/scanner.c`'s external scanner, and cannot call the Lua one in
`core/utils/chat_excerpt.lua`. `tests/lua/infrastructure/treesitter_tool_span_spec.lua` holds them
to the same answers on the cases that shaped the rule. They part company only past the point where
the count fails: the grammar stops at a chat boundary and `chat_excerpt` stops at the first blank
line, each conservative for what it is protecting.

Changing any of this means rebuilding the parser (`./build.sh`); the compiled grammar is what a
running Neovim loads.

## Code Fences Written into the Buffer

A model sometimes ends a code block and keeps writing on the same line:

````text
```これで完了です
````

CommonMark does not accept that as a closing fence — a closing fence may be followed by whitespace
only — and `tree-sitter-vibing/src/scanner.c` implements the same rule, so the block stays open
until the next `## <Kind>` header and everything in between is highlighted as code. The chat is
still valid Markdown; it just reads as one long code block.

`core/utils/markdown_fence.lua` splits that line in two as it is written, at the three write paths
that put model-authored Markdown into the buffer: `streaming_handler.flush_chunks` (the streamed
reply), `renderer.addUserSection` (a `Request` / `Report` / `Notice` body delivered from another
chat) and `summary_inserter` (the `## summary` block).

Two decisions inside it:

- **A remainder that looks like an info string is left alone** (` ```json `). Inside a block that
  is body text to CommonMark too, so splitting it would rewrite a nested Markdown example rather
  than repair anything. The split happens only when the remainder does not match
  `^[%w_%.%+#-]+$` — that is, when it contains a space or a non-ASCII character.
- **Streaming does not wait for the line to be complete.** A chunk boundary can fall anywhere, and
  splitting early is safe because the rest of the line is appended to the line the split produced;
  the finished text is identical either way. A prefix of an info-string-looking word is itself
  info-string-looking, so no split can be triggered early and then turn out wrong.

The open-fence state is recounted from the buffer on every flush, from the last message header
down, rather than carried across chunks: `flush_chunks` already reads every line, a header
terminates an unfinished fence anyway, and a recount cannot drift when a stream is interrupted or
the user edits the buffer mid-turn.

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
`nvim_ask_user_question` (`claude-plugin/mcp-server/src/tools/chat.ts`), which the Claude and Codex
prompts instruct the model to use instead of the native tool. The backend-specific qualified tool
names differ, but both prompts use the shared text in
`adapter/modules/ask_user_question_instructions.lua`. Its handler calls
`M.ask_user_question()` in `infrastructure/rpc/handlers/permission.lua`, which renders the choice
list via `on_insert_choices`.

**What happens to the turn depends on the backend** (#788). Where a measurement covers it — claude
only, `mcp.measured_answer_wait_sec` — the reply to the MCP call is withheld, the turn stays open,
and the user's `<CR>` becomes the tool's return value. Everywhere else the turn is cancelled as
before and the answer arrives as the next `--resume`d turn's user message. The withheld reply, its
four exits and what expiry means are
`handbook/architecture/approval-without-kill.md` → "The other channel".

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

### Codex backend

Codex 0.153 and later use the same choice-list path. `codex_plugin_config.lua` names the normalized
`mcp__vibing_nvim__nvim_ask_user_question` tool and embeds the stable chat buffer number in
`developer_instructions`; `codex_cli.lua` puts that same number in the process registry, so the
shared RPC handler resolves the correct turn even when several chats are active.

The two things that originally made this impossible (#532) were added in Codex 0.153:

- Codex now takes a system prompt seam: `-c developer_instructions` becomes the first `developer`
  message. Context and language are still prepended to the user prompt.
- Headless `codex exec` still auto-cancels an MCP call at its own approval prompt — stdin is
  closed, so EOF reads as a denial ([openai/codex#24135][codex-24135]) — but
  `-c mcp_servers.<name>.default_tools_approval_mode="approve"` is a per-server answer to it, and
  is how the bundled server reaches codex at all (`handbook/architecture/plugin-and-commands.md` →
  "Codex").

The UI path is covered by the same E2E spec as Claude. Ordinary tool approval remains a different
route: the `ask` permission list resolves on the turn id, while the model-called question tool
resolves on the stable `chat_bufnr` to avoid putting a per-turn identifier in the prompt.

[codex-24135]: https://github.com/openai/codex/issues/24135
