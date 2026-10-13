# Chat UI: Subagent Output, Timestamps and AskUserQuestion

Moved out of `.claude/rules/features.md`. The always-loaded rule for each of these is one line in
that file; the reasoning and the traps are here.

## Subagent Output Visibility

The Claude CLI hides everything a subagent says unless it is launched with
`--forward-subagent-text`; without the flag a `Task`/`Agent` call shows only its header and final
result. `ui.subagents.show_output` (default `false`) opts in, and
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
so `ai.agents.claude.extensions.background_wait_sec` (default 3600, `0` for no limit) is passed as
`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`.

### What the stream carries

`system/task_started` announces a launch and is tracked only when `is_backgrounded` is set — a
foreground subagent closes inside its own turn as a `tool_result`, so recording it would leave it
unreported forever. The payload also carries `tool_use_id`, `subagent_type` and `description`; only
`description` is decoded, because it is the brief the completion line names the task with.

`system/task_notification` is the completion:

```json
{
  "subtype": "task_notification",
  "task_id": "a800809d218e08d3b",
  "tool_use_id": "toolu_01K3di…",
  "status": "completed",
  "output_file": "…/tasks/a800809d218e08d3b.output",
  "summary": "PONG",
  "usage": { "total_tokens": 19469, "tool_uses": 0, "duration_ms": 1610 }
}
```

`task_id` is the same identifier `subagent_marker.lua` scrapes out of the tool result as `agentId`,
and the same one naming `subagents/agent-<id>.jsonl`. One id, three places.

Only the completion is drawn (`subagent_display.format_completion`), and only its metadata. The launch is
already on screen as the `Agent(...)` tool line, and the subagent's answer reaches the model through
the notification — printing the summary here would show every report twice.

### A turn that ends with subagents outstanding

Upstream drops a notification that arrives while the parent is mid-turn
(anthropics/claude-code#87675: 19 subagents launched, 15 notified, the parent idle for hours). That
one is not vibing's to fix. What is vibing's is the consequence: **a turn whose started-minus-notified
set is non-empty has nothing left that will ever start another turn on that chat**, and per
`architecture.md` starting a turn is the only way to deliver anything to one. The chat sits dead
until a human types into it, and what the human sees is "the response just stopped" (#820). Observed
on a `/simplify` run: four `Agent(...)` lines, "I'll report once all four come back", then nothing
until the user asked what had happened.

So the end of every turn asks `BackgroundTasks.report()` for two things, and they are not the same
thing:

- **the outstanding set** — everything launched with `is_backgrounded` that never reported. This is
  the wake signal.
- **what could be recovered** — each outstanding subagent's own transcript, read back off disk.
  This is content for the notice, and it is empty in the case that matters most.

**Keying the wake on recovery was the defect.** Recovery only yields text for a subagent that has
already _finished_ and written its answer; the subagent that is still _running_ has nothing on disk
yet, so empty recovery meant silence in exactly the state that leaves the chat unreachable. The
partial case was the same hole one step in: four outstanding and one recoverable reported that one
and silently abandoned the other three. The notice is therefore built by walking the outstanding set
and splitting it on whether a recovered answer exists for that `task_id` — which is why
`Vibing.RecoveredSubagent` is `{ task_id, text }` and carries no display label of its own. The launch's
`description` is already on the `Vibing.BackgroundTask` the answer belongs to, so naming the block
stays with the chat layer that renders it, and both groups name a task the same way.

This does **not** reverse the older rule that recovery reports only what it found. "A subagent
finished and here is nothing" is still worse than staying quiet; "these two are still running, go
collect them" is a different sentence and an actionable one. The first describes a subagent, the
second describes the chat's own predicament.

Two things bound it. It is **not** behind `automation.orchestration.notifications.enabled` — the same
"cannot leave this stop on its own" class as `asked_question` / `waiting_approval` / `error`, and an
opt-in would leave the silent stall as the default behaviour. And it **does not wake a `_cancelled`
turn**: that flag covers both `:VibingCancel` and the kill that draws a question or an approval, and
neither is an abandoned chat — the first was stopped on purpose, the second has a prompt on screen
whose answer starts the next turn.

The loop this could have been is closed structurally rather than with a budget. On oneshot the ledger
lives on `event_context._background_tasks`, which `cli_adapter.stream()` builds fresh per turn, so a
`task_notification` arriving in turn N+1 finds no entry from turn N and the wake happens at most once
per turn that actually left work behind. On duplex the ledger is the process's and the wake is the
reclaim, which happens once per process (`forget`'s `_gone` guard). Either way one outstanding set
cannot wake twice, so no counterpart to `completion_notifier`'s `max_wakes` is needed, and adding one
would be state with nothing to protect.

The transcript location is derived rather than remembered, because a task that was never notified
never told us its `output_file`.

### The same question under the duplex transport

"Will anything report these?" is answerable only where the process is finished with turns, and on the
resident transport that is not the end of a turn. #838 put the read in `cli_adapter`'s `finish` — true
of oneshot, where `finish` _is_ the exit handler — and had to gate duplex off, because there `finish`
runs on the CLI's `result` line with the process alive and the subagents still going: reading the
ledger at that point interrupts every fan-out the instant it starts. #840 moves the duplex read to the
moment the statement becomes true again, which is `duplex_pool`'s reclaim.

**A reclaim route declares what it meant; nothing infers it.** All of them are "the process is gone",
and they differ on two things: whether anybody still needs telling, and whether the pool explicitly killed
the CLI. `duplex_pool` resolves both from the route into a `Vibing.DuplexReclaimVerdict` before
announcing it, so `Vibing.DuplexReclaimReason` reaches no signature outside that module and no consumer
re-decides what a route means. `QUIET_RECLAIM` names the four routes nobody needs telling about —
`restart` (a turn is being started on the replacement in that same call), `shutdown` and `chat_closed`
(no loop left, or no buffer), and `cancelled` (a human stopped this chat, the judgement `_cancelled`
makes one layer up). The default is therefore to report, so a route added later wakes rather than
silently dropping the wake, which is the shape of the hole being closed. The verdict is acted on in
`duplex_routing.exit_handler`, the one place that already knows a process is gone by every route.

**The idle timer is the route that matters, and the conflict it looks like it has is not one.** "Idle"
is about turns, so the timer fires on a process that still has a background subagent in flight — and
because a background subagent runs _inside_ the CLI, the reclaim is what makes its answer unreachable.
Holding the process back instead was rejected: nothing else would ever release it (a notification
arriving between turns does not reset the timer, and a CLI-initiated turn is not something this
transport picks up yet), so it trades a woken chat for a resident 200MB process that never leaves. The
five minutes are not wasted either — they are the window in which the CLI's own notification can still
arrive and take the entry off the ledger, and then there is nothing to report.

The notice keeps two forms to explain how the CLI ended, with a separate question for saved
answers. `process_killed` says whether the pool explicitly killed the process; its false value on
`exited` does **not** assert that any subagent survived. Both forms preserve the recovered
transcript text. The exit form asks for saved output and re-dispatch or resume if no answer is
available, and explicitly says not to wait for a notification from the exited CLI. This corrects
`COPY.alive`'s former "may still be running" claim without replacing it with an unmeasured promise
that every possible exit always kills every possible kind of work.

### CLI lifetime measurement

Measured on 2026-10-13 with Claude Code **2.1.286**, parent and general-purpose background agent
both **`claude-haiku-4-5-20251001`**. Driver: `tests/perf/background_subagent_lifetime.py`, guarded by
`VIBING_PERF=1` and outside `npm test`. The adjacent Node tests exercise only its accounting and
classification, with no paid CLI calls.

The observations were selected before the run: parent/descendant process state, new work after
parent exit, and output recovery. Each agent wrote a start marker, waited, then had to use a
**separate Write tool** to create a completion marker. A surviving sleep process or an old
transcript alone could not prove agent survival. Samples every 0.5 seconds retained discovered
PIDs after reparenting and their process state; a zombie was not treated as a live worker.

Ordinary print mode waits for background agents. To obtain an exit while work remained pending,
the two exit cells used **`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=2000`**, the CLI's own wait ceiling,
rather than a harness signal. The live duplex control used the same setting but kept stdin open
until the work progressed. These are different from forcing the CLI to exit with SIGTERM.
The [upstream headless documentation](https://code.claude.com/docs/en/headless#background-tasks-at-exit)
describes the wait ceiling; the timings and observations below are from the actual local run.

| Condition                                                | State at parent exit                                                                        | Work afterward                                                                                             | Saved-answer recovery                                                                                                       |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| oneshot, stdin already closed                            | exit 0 at 11.895s; start marker present, completion marker absent; agent notified `stopped` | No completion marker or further agent-transcript growth in the following 90s; no live recorded descendants | Same-session `--resume`: actual Bash tool called the plugin's `claude_subagent_transcript.recover`, returned `[]`           |
| duplex, stdin closed after launching `result` at 11.388s | exit 0 at 14.603s; start marker present, completion marker absent; agent notified `stopped` | Same absence of new work for 90s; no live recorded descendants                                             | Same reader through an actual resumed CLI tool call, returned `[]`                                                          |
| duplex with open stdin                                   | Parent alive and a successful separate completion Write observed by 56.651s                 | Establishes only that the task can progress while the parent is alive                                      | Not a natural-exit or recovery cell; final agent `task_notification` completion was not confirmed before budget termination |

The live control is accepted **only** as evidence that work can progress with a live parent. It was
stopped for budget reasons and supplies no evidence about natural exit. A completion notification
for its nested Bash command is not the background agent's own completion. The driver now matches
that notification to the launched agent's task id before declaring full control completion.
Completed-before-exit cells, missing launch/start markers, failed exits and forced exit cells are
excluded from conclusions about post-exit lifetime.

Under the two measured ceiling exits, pending work did not continue and no answer was recovered.
That contradicts using "may still be running" as advice for **these** exits. It does not prove what
happens for every CLI version, backend, model, abrupt crash, server-side operation or wait setting.
The production oneshot normally waits too: it may have an unreported **finished** agent whose
notification was lost, while an unfinished agent at process exit may require the wait ceiling to
have expired. The production default ceiling is 3600s (0 disables it), not the measured 2s. No
claim that shortening it reproduces every production exit is made, and the new copy consequently
states only that the CLI exited and no answer was recovered; existing saved answers remain useful.
The duplex `exited` predicate records the same observed action, not an opposing agent-lifetime
verdict. Its internal field is now named `process_killed` to make that distinction explicit.

**Cost and failures:** cumulative observed input **308,148 tokens**, output **5,571 tokens**,
including cache reads/creation. This exceeded the approved 300k input cap by 8,148. Polling usage
cannot stop a model request already in flight; the live cell needed extra requests beyond its
estimate. No additional paid run followed. Accounting deduplicates API message ids and takes
per-session cumulative `modelUsage` high-water marks across resume, including cache usage, rather
than adding replayed results. The live cell has no final complete usage result; its latest
assistant/transcript usage is included conservatively.

The guard now reserves 120k input before a new cell, 50k before a recovery turn, and 20k for a
request in flight during observation, plus output headroom. With the measured 203,882 tokens
already spent before the live cell, the revised admission guard would refuse that launch. This is
a conservative stop guard, **not** an exact upstream token cap. It preserves evidence on a budget
stop. Re-running with `--prior` includes earlier attempts in the same budget.
The first TaskOutput recovery prompt was unusable because 2.1.286 advertises no TaskOutput tool;
its prose `UNAVAILABLE` was excluded and replaced by the actual plugin-reader tool observation.
An initial duplex attempt stopped just after init was also excluded. The later oneshot reader
finished and saved its result before a log-only `NameError`; that print error was fixed without
re-running inference. The three accepted observations and both reader results were retained.

**The ledger has to follow the process, not the turn** (`background_tasks.share`). A
`task_notification` for a subagent launched in turn N arrives after turn N — most often between turns,
where `duplex_routing.line_router` sends it to `_idle_context`. A per-turn ledger takes the entry off a
copy nobody reads, and every later reader is still owed a report for a subagent that reported. Both
turn contexts and the idle context therefore alias the record's one table. That is also why the duplex
arm of `cli_adapter`'s `finish` skips `BackgroundTasks.report` entirely rather than discarding its
result: the call reads a transcript off disk as soon as the set is non-empty, which under a shared
ledger would be once per turn for nothing.

`adapter/` requires nothing from `application/`, and "does this chat need a turn" is not an adapter
question, so the finding leaves through `opts.on_subagents_orphaned` — the same shape as
`on_insert_choices` and `on_approval_required`, and the only callback on the opts whose caller outlives
the turn that supplied it. It is reinstalled every turn, because `cwd`, the descriptor and the session
id are the newest turn's and are the only ones that can still be right. And the report is
`vim.schedule`d: waking the chat starts a turn that calls back into `duplex_pool.acquire`, and the
reclaim it would re-enter has not killed its process yet.

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

**Implementation: a block in the reply, not a tool.** Every backend's prompt
(`adapter/modules/ask_user_question_instructions.lua`) tells the model to end its reply with one
fenced block whose info string is `vibing-question`, holding
`{"questions": [{"question", "multiSelect", "options": [{"label", "description"}]}]}`, and to stop.
When the turn succeeds, `send_message.lua` calls `ChatBuffer:take_question_block`, which asks
`presentation/chat/modules/question_block.lua` for a block that ends the reply, takes it out of the
transcript (otherwise the question shows twice, once as JSON) and stages it with `insert_choices`.
The turn's closing `add_user_section` draws the choices; the user's `<CR>` is the next turn.

**Why it stopped being a tool.** `nvim_ask_user_question` (#788) held its MCP reply open until the
human answered, which needed a withheld-reply registry with four exits, a measured ceiling on how
late an answer is still consumed (960s on claude), an exemption from every "this chat is
responding" guard, and a rule for which of two blocked questions an answer belonged to. All of it
bought one thing over ending the turn: the CLI process surviving while the human thinks. Once
duplex became the default the resident process survives between turns anyway, and the prompt cache
is server-side either way, so the cost bought nothing. A block also reaches Grok, which never could
call the MCP tool. The tool's design history is `handbook/superpowers/specs/2026-07-10-ask-user-question-mcp-tool-design.md`.

**Only the last thing written counts.** `find_trailing` accepts nothing but blank lines after the
closing fence and refuses when a later fence closes the reply, so a quoted example of the format
never becomes a live prompt. That is also why the block is taken **before** `### Tokens` and
`### Modified Files` are appended under the reply.

**The chat reports `asked_question` until its next send** (`insert_choices` sets `_stop_reason`).
It is idle, so an orchestrator answers with an ordinary delivery.

Native `AskUserQuestion` is unavailable in headless `claude -p` mode and opaque to vibing.nvim, so
the PreToolUse hook denies it — without killing the turn — with a reason that names the block.
