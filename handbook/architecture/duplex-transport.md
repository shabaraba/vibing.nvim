# The Duplex Transport: one resident CLI process per chat

Opt-in for Claude and Codex, default off. Turn it on with `backends.claude.process = "duplex"` or a chat's
own `process: duplex` frontmatter. Why it exists, what it cost, and the five things that had to move
before it could work at all.

Chats that can never use it, whatever the configuration says: a lightweight call (title generation,
`/summarize`), a subagent chat, and every backend other than Claude and Codex. `process_model.lua` is the one
place those exclusions live.

Identifier background is `processes-and-turns.md`; this file assumes `process_id` and `turn_id` are
already two things.

## What it is

The oneshot transport spawns `claude -p ... -- <prompt>` per turn and reads its stdout until the
process exits. That exit **is** the turn's completion signal: `stream_handler.create_exit_handler`
is the only normal path to `on_done`.

The duplex transport spawns `claude -p --input-format stream-json ...` once, with no prompt in the
argv, and writes each turn's prompt to its stdin as a `user` message. The process has no reason to
exit, so it serves the next turn too — and the CLI's per-process startup cost (binary load, plugin
scan, MCP server launch, `CLAUDE.md` read, system prompt assembly, git status block) is paid once
per chat instead of once per message.

## The measurement

Taken with `tests/perf/duplex_latency.lua`, which loads vibing.nvim exactly as a chat does — the
`--plugin-dir` list, the MCP server, the project's `CLAUDE.md`, the real system prompt — and changes
one thing between runs. What is timed is `stream()` returning to the first stdout line reaching the
decoder, which is the latency a resident process is meant to remove.

claude 2.1.236, this repository as the working directory, `sonnet`, three turns per transport, the
same trivial prompt each time. Per-turn, not averaged — the average is the one number that hides the
result, because turn 1 is supposed to be identical and turns 2+ are the whole claim.

| turn | oneshot | duplex |
| ---- | ------- | ------ |
| 1    | 881ms   | 871ms  |
| 2    | 850ms   | 158ms  |
| 3    | 872ms   | 154ms  |

Turn 1 is a tie, and has to be: the process is cold either way. From turn 2 the resident process is
**5.4x** faster to the first event, and whole-turn wall clock fell with it (5.9s → 2.2s on turn 2,
5.6s → 2.3s on turn 3). The ~700ms it removes is the CLI's own startup — binary load, plugin scan,
MCP server launch, `CLAUDE.md`, system prompt assembly — which oneshot pays once per message.

### The interrupt, measured

Sent mid-turn against a live generation: **the turn ended 16ms later**, the process stayed up, and
the next turn on that same process was back to 154ms. That is the completion condition "an interrupt
stops the turn and not the process", end to end against the real CLI.

`duplex_routing.INTERRUPT_GRACE_MS` is 5000ms against that 16ms — ~300x, deliberately. The measured
number is the _responsive_ case, and the case the fallback exists for is the opposite one: a CLI
wedged inside a tool call may not read its stdin at all. The grace period is therefore sized by how
long a user will wait after pressing cancel, not by the round trip, and the round trip only says the
normal path will never reach it.

### Usage is reported per turn, not per session

Worth checking before trusting the per-turn event context, because a cumulative `result.usage` plus
a per-turn accumulator would over-report every turn after the first. Read straight off the wire:

| turn | duplex `cache_read` | duplex `cache_creation` |
| ---- | ------------------- | ----------------------- |
| 1    | 30,923              | 36,464                  |
| 2    | 67,387              | 2,668                   |
| 3    | 70,055              | 63                      |

Turn 3 creates 63 tokens of cache, not the ~39k a running total would show, and `read` tracks the
conversation's own growth exactly as it does under oneshot. `requests` is 1 on every turn under both.
So the numbers are per turn, and cutting the event context on `result` reports them correctly.

(vibing.nvim never reads `result.usage` anyway — `handlers.usage` accumulates the per-request `usage`
on each `assistant` message, and `claude_stream_json`'s `result` arm emits only `error` and
`turn_end`. The check above is about what would happen if that ever changed.)

## The modules

| module               | what it is about                                                             |
| -------------------- | ---------------------------------------------------------------------------- |
| `process_model.lua`  | Which model this turn runs under, and the three cases held at `oneshot`      |
| `duplex_process.lua` | One OS process: `jobstart`, line assembly, `chansend`, interrupt, stop       |
| `duplex_pool.lua`    | One process per chat; the reuse decision and the four ways one is reclaimed  |
| `duplex_stream.lua`  | The duplex tail of `stream()`: the reuse key, acquire, send                  |
| `duplex_turn.lua`    | One turn's lifetime on a process that outlives it                            |
| `duplex_routing.lua` | The four things that reach a process, not a turn, and how they find the turn |
| `turn_outcome.lua`   | Shared with the oneshot path: the first-byte budget and every response shape |

## What had to move

### 1. `Vibing.CanonicalEvent` had no "the turn is over"

The renderer's arms covered text, tools, usage, errors — everything a turn _contains_, nothing about
its end, because the process exiting had always said that. A successful `result` line produced no
event at all (`claude_stream_json` emitted one only for `subtype == "error"`).

So `result` now always emits `{ kind = "turn_end" }`, after the `error` arm it may also emit, and
`event_renderer` has a `turn_end` handler that calls `context.onTurnEnd` if one is set. The oneshot
path never sets one, so the event is decoded and dropped there. That ordering is load-bearing: a
turn the CLI declared failed has to have reached `resultErrors` before anything completes on it.

### 1b. Whose `result` is this?

`turn_end` says a turn ended. It does not say **which** turn, and on a resident process that is not
the same question. The CLI runs turns nobody asked for: a background subagent finishing delivers a
`system/task_notification`, and the CLI answers it **by itself** — a full `system/init` … `result`
pair on the same process, with no prompt from vibing anywhere in it. `duplex_turn` consumed the
first `result` it saw, so one of those landing between a prompt and its answer ended the user's turn
with nothing in it. The real answer then arrived on a process with `_turn = nil`, went to
`_idle_context`, and was dropped. Once that happens the chat is off by one: the next turn is closed
by the previous turn's `result`, forever.

Seen in production before it was understood (`#842`): three empty `## Assistant` sections in one
session, one of them swallowing four and a half minutes of work and a whole subagent run.

#### The correlation is the CLI's own, and it has to be asked for

Measured against claude 2.1.273 (`tests/perf/duplex_foreign_turn_end.sh`). The input envelope takes
a `uuid`; supply one and the CLI echoes it back:

| the turn                               | `result.user_message_uuid` |
| -------------------------------------- | -------------------------- |
| an ordinary prompt                     | the id we wrote            |
| a slash command (`/compact`)           | the id we wrote            |
| a turn stopped by `interrupt`          | the id we wrote            |
| one the CLI started for a notification | **the key is absent**      |

All four cells matter. Cell 4 is the one being rejected, but on its own it licenses nothing — a CLI
that does not echo at all produces exactly the same absence. Cells 2 and 3 are not decoration
either: had either lost the id, this design would hang `/compact` and `<C-c>` rather than repair
anything, and the fix would have had to be a different one.

#### A missing field is not evidence, so the gate arms on proof

`duplex_turn.ends_this_turn` refuses nothing until it has seen the CLI name **this turn's own**
prompt back. That proof is `command_lifecycle`, which the CLI emits only when the envelope carried a
`uuid`, and which arrives on the `queued` state milliseconds after the write — long before any turn
could finish. A CLI that never emits it keeps the pre-#842 behaviour of ending on the first
`result`, which is wrong in the rare case and not a hang; rejecting on absence alone would leave the
turn open until the first-response watchdog killed the process.

The id is `"vibing-" .. turn_id` rather than a fresh one: the two name the same thing, and a second
identity for it is a third id to keep in step. The CLI does not validate the shape — arbitrary
strings are echoed unchanged.

#### What the foreign turn's output does instead

Nothing is discarded. While a vibing turn is open, `line_router` feeds every line to that turn's
context, so the CLI's own answer to a notification renders **inside the section the user is
reading** — which is what #829 wanted in the first place. Only the `result` is refused. A foreign
turn that runs while no vibing turn is open is a different hole, and still `#840`'s.

### 2. The spawn primitive is different

Every adapter path used `vim.system`, which returns no writable channel. The only primitive that
does is `jobstart` + `chansend`, and the only existing user of it was
`completion/cli_command_list.lua` — which is where the line-assembly buffer, the `request_id`
correlation and the idempotent finish latch in `duplex_process.lua` come from.

### 3. `kill_tree`'s justification inverts, and it is still needed

`cli_runtime.kill_tree` walks descendants because `vim.system`'s exit does not fire until stdout
closes, and the CLI's shells and MCP servers hold that pipe. Under a resident process exit is no
longer a completion signal for anything but the process — but Neovim also flushes a job's streams
before firing `on_exit`, so the same descendants would hold the same pipes. `duplex_process.stop`
therefore goes through the same walk, handing it a `{ pid, kill }` surface.

Four routes reclaim a process: `VimLeavePre`, the five minute idle timer, the argv change below, and
the CLI dying on its own. Only the last of them arrives as an `on_exit` callback, which is the trap:
a route that announced nothing left the adapter's `_processes` table holding a handle to a process
that no longer existed, and `cleanup_stale_sessions` reads that table as "still running" and keeps
the session entry alive forever. So `duplex_pool.forget` carries the notification itself, once per
process, on every route.

**What the routes mean is not the same thing, so the notification carries that too.** They are all
"the process is gone"; only some are also "and no turn is coming", which is what separates a chat
merely between messages from one left holding unfinished work. Each `Pool.stop` caller names a
`Vibing.DuplexReclaimReason`, and `QUIET_RECLAIM` names the four that mean nothing needs saying —
`restart` (a turn is starting on the replacement in that same call), `shutdown` and `chat_closed`
(nowhere to say it), and `cancelled` (a human stopped this chat). The default is therefore to report,
so a route added later is heard from rather than silently dropped, which is the shape of the hole #840
closed. Three of the seven reasons sit outside the four routes above because they are the `Pool.stop`
callers outside the pool: `unresponsive`, `cancelled`, `chat_closed`.

**The vocabulary stays inside the pool.** `forget` resolves the reason to a single boolean before
announcing it, so `_on_gone` receives "is anything still coming for this chat" and not the reason
string — the pool owns the routes, `duplex_routing` owns what to do with a dead process, and
`Vibing.DuplexReclaimReason` appears in no signature beyond `M.stop` and `forget`. #840 is the first
consumer: a background subagent runs inside the CLI, so a reclaim takes it down and somebody has to
tell the chat. `handbook/features/chat-ui.md` → "The same question under the duplex transport".

The `_gone` guard is what makes the route's decision stick. Every deliberate reclaim runs `forget`
before the kill, so the job's real `on_exit` — which would arrive a tick later as `exited`, the reason
that always reports — finds the process already forgotten and says nothing. Without it, `:VibingCancel`
would wake the chat it had just stopped.

### 3b. A dying process must be identified, never looked up

Three callbacks reach a process rather than a turn — stdout, stderr, exit — and all three were
originally written as "ask the pool what this chat is using". That is wrong on exactly one path, and
it is the path the feature is built around.

`jobstop` only _asks_. Neovim flushes the job's streams before firing `on_exit`, while the
replacement is installed synchronously in the same tick, so the dying process's callbacks always
land **after** its replacement is registered under the same chat key. Looked up by chat, they
answered with the replacement: the exit callback unregistered it, ended its freshly-opened turn with
`The CLI exited with code 0`, and orphaned a live ~200MB CLI that no reclaim route could reach any
more; the stdout router fed the dead process's buffered bytes into the live turn, where a `result`
among them would end it before it had produced anything.

So the record travels with the callback and every one of them asks _am I still the current process_,
never _what is current_. The unit tests could not see this until the `jobstop` stub stopped firing
`on_exit` inline: `state.flush_exits()` in `tests/helpers/adapter_stream.lua` is the tick Neovim
takes, and it exists so this ordering is testable rather than argued about.

### 3c. A busy process is not reusable

`ChatBuffer:send_message` guards only `_is_sending` — the `<CR>`-to-spawn window — and relied on
`cancel_request` closing the previous turn **synchronously**. That is true of a kill and not of an
interrupt, so routing the user's cancel through `stop_turn` quietly removed the guarantee the send
path was built on.

`duplex_pool.acquire` therefore refuses to reuse a process that still has `_turn` set, and replaces
it instead. `M.stop` ends the orphaned turn properly on the way out, and the interrupted turn's
`result` can no longer reach the new turn because it is a different process. Reusing it would have
leaked the old turn's registry and permission entries, completed the _new_ turn with the _old_
turn's output, and left the old turn's kill-fallback timer armed to fire into the middle of the new
one.

### 4. Conformance forbade duplex directly

`descriptor_shape_spec` asserted `stdin == nil or ""` and `request_spec` asserted the prompt appears
in the argv exactly once. Both are true of oneshot and neither is a fact about a backend, so they
branch on `descriptor.process` the same way the hook assertions already branch on
`descriptor.hook.transport`. The duplex branch asserts the opposite where the opposite is correct —
no prompt in the argv, `--input-format stream-json` present, `--resume` still present — and the
oneshot assertions are unchanged.

### 5. `transports.wanted(hook, opts)` is decided per turn; a process is flagged once

`permission_mode` comes from frontmatter and can change between turns, and it changes the argv.
A live process was handed its flags at spawn and cannot be re-flagged, so **the argv is the reuse
key**: a turn whose argv differs from the one the process was started with gets a new process,
resuming the same conversation.

**The key is built with no session id.** This is the trap the whole feature dies in otherwise: turn
1 has no `--resume` and turn 2 does, so an argv-as-written key differs by construction on every
chat's second turn, every chat restarts its process every time, and the measured win is exactly
zero while the code looks correct. `duplex_stream` therefore builds the argv twice — once with the
session for spawning, once without it for the key.

## One bad line used to cost the process, not the line

A turn ends on `result` and on nothing else here, so anything that stops `result` from being
decoded stops the chat forever. `/compact` was that thing.

Measured against claude 2.1.x by driving `--input-format stream-json` from a script
(`printf` a `user` message, sleep, repeat), a real compaction emits:

```text
system  compact_boundary  {"trigger":"manual","pre_tokens":23707,"post_tokens":1114,"duration_ms":8905}
user    content = "This session is being continued from a previous conversation…"   ← a string
user    content = "<local-command-stdout>Compacted </local-command-stdout>"          ← a string
result  subtype=success                                                              ← ends the turn
```

Those two `user` events are the only ones observed whose `message.content` is a plain string rather
than a block list, and `claude_stream_json.tool_blocks` ran `ipairs` on it. Three things followed,
in order, and only the third was visible:

1. the raise escaped `duplex_process.absorb`, which is a `jobstart` `on_stdout` callback, so the
   rest of that batch was dropped — and the `result` line is routinely in it;
2. `record._pending` was reset **after** the dispatch loop, so it kept the failed line's fragments;
   every later line was concatenated onto them and stopped parsing as JSON;
3. the process went on living and answering, and the chat sat at `responding` — measured at 12
   hours, ended only by the CLI eventually dying.

The oneshot transport hid all of this: the process exits at the end of a turn, and that exit
completes the turn whatever the stream did. So the cost of a decoder bug is a transport property,
which is why the containment lives in two places now — `absorb` carries the framing state forward
before it dispatches anything, and `stream_decoder.processLine` `pcall`s the decode so one line
degrades to an unprocessed line and a single notification.

**A cancel that finds nothing is not a cancel.** The same incident exposed the other half:
`:VibingCancel` reached `adapter:stop_turn` directly and ignored what came back, and `stop_turn`
answered the same silence for "interrupt sent" and for "that process was reclaimed an hour ago".
Since `_is_sending` is cleared only by a turn ending, a chat whose process is already gone could
never be recovered — pressing cancel did nothing, repeatedly. `stop_turn` now returns whether
anything was actually asked to stop, and `ChatBuffer:cancel_turn` folds the chat's own turn through
`_finish_turn` when the answer is no. `cancel_request` keeps the old meaning, because
`send_message`'s zombie reap calls it while `_is_sending` may legitimately be set for a prompt being
answered in place (#788).

## One answer to the first-byte question

The resident transport shipped (#781) with its own first-response watchdog and its own copy of every
response shape, and left a comment on each half telling the next person to keep them equal. #782
merged them into `turn_outcome.lua`. Three things came out of doing it that are worth keeping.

**The "keep these equal" comments could not have been honoured, and no test could have noticed.**
`cli_adapter.lua` read the oneshot budget into a `local` at **module load**
(`local INITIAL_RESPONSE_TIMEOUT_MS = CliRuntime.INITIAL_RESPONSE_TIMEOUT_MS`), so the value one
transport actually armed was unobservable from outside: assigning a different number to either
module's constant at runtime changed nothing. The merged constant is read at the moment each
watchdog arms, which is what makes the one assertion that matters possible —
`first_response_watchdog_spec.lua` sets the shared value to 60ms and requires **both** transports to
fire on it. A transport that kept a copy produces no response at all inside the test's patience and
fails; comparing the two numbers to each other, which is what the comments asked for, would have
passed against two independent constants that happened to agree.

**There were eleven response literals, not the three the issue counted.** Four pairs were the same
response written twice — a failure before any process existed (`cli_runtime.report` /
`duplex_stream.fail`), a cancellation (`cli_runtime.spawn`'s handle /
`duplex_routing.cancellable_handle`), a turn that ended on its own terms
(`stream_handler.create_exit_handler` / `duplex_turn.onTurnEnd`), and the watchdog. The count is why
the spec ends with a repository scan rather than with call-site assertions: this repository's
recurring failure is following a new discipline at the call sites the author had in mind and missing
one, after which nothing fails. `[^%w_]_turn_id%s*=` over `lua/vibing/infrastructure/adapter/` must
match only `turn_outcome.lua`.

**Merging found a real defect on the oneshot side.** Its watchdog killed the process and _then_
reported, and `cancel()` completes the same turn as a plain `Cancelled` on its way out. Completion
is idempotent, so the first response through wins: the `_session_corrupted` response was constructed
and discarded on every firing. The session was never reset, the "Session Timeout" notice was never
written, and the `_cancelled` on the response that replaced it suppressed the `**Error:**` line too
— a hung resumed session ended the turn with an empty assistant section and no message of any kind,
leaving only a `vim.notify`. duplex had the same ordering during #781's development, found it, and
fixed only its own half; the oneshot half stayed as it was because #777 was scoped not to touch it.
The fix is one statement, stated once, on `turn_outcome.first_response_timeout`: hand the response
back before killing anything.

## What is deliberately not here

- **Neither an approval nor `AskUserQuestion` is answered over the open stdin.** Doing it as a
  `control_response` was built and then reverted (`51a242b5`, which records the shape and the
  conditions for reviving it). #778 removed the approval kill in a way that needs no control
  channel at all, and so applies to both transports: the hook simply **does not write its `.res`**
  until the human answers. A backend with a `measured_wait_floor_sec` therefore waits in place, and
  only a backend without one keeps `cancel_and_deny` — which relies on `cancel` running
  `wrapped_on_done` synchronously and on the process being gone afterwards, which is what makes
  that backend's retry message a _new_ turn. **`AskUserQuestion` does still kill the process**, and
  is its own issue. The user-facing cancel is the only path routed through the new `stop_turn`,
  which sends `control_request {subtype: "interrupt"}` and keeps the process; the CLI answers with
  a `result` of subtype `error_during_execution` and serves the next turn normally.
- **Lightweight calls stay oneshot.** The bargain in `core/types.lua` — no tools, no project config,
  no user MCP servers, no hooks, `utility_model` — is not something a process serving a chat is also
  keeping, and one process cannot hold both sets of flags.
- **Subagent chats stay oneshot.** A subagent chat shares its parent's `session_id` permanently, and
  a resident process holds its `--resume` for its whole life; two of them would sit on one
  transcript indefinitely, which is the corruption `process_registry.find_other_holding_session`
  exists to refuse, made permanent.
- **Every other backend stays oneshot.** `descriptor.process` is a ceiling, not a default: a
  descriptor that does not declare `duplex` cannot be configured into it.

## Why the descriptor field is called `process`

`transport` was taken. `Vibing.HookSpec.transport` names one of `settings_file` /
`config_override` / `plugin_dir` / `project_dir`, and two conformance specs branch on it. A second,
unrelated `transport` in the same descriptor is how a branch ends up reading the wrong one.


## Codex app-server

Set `backends.codex.process = "duplex"`, or `process: duplex` in a Codex chat.
The existing per-chat pool, process/turn registries, five-minute idle reclamation and
interrupt watchdog also serve Codex. Lightweight calls and subagent chats remain oneshot.

Codex uses newline-delimited JSON-RPC on `codex app-server --listen stdio://`.
`codex_duplex_protocol.lua` performs initialize → initialized → hooks/list → thread/start (or
thread/resume) → turn/start; subsequent messages send only turn/start. Replies are
correlated by request id. Notifications arriving before the turn/start reply are queued
until its turn id is known; another thread or turn cannot finish the active request.
`turn/interrupt` addresses that same thread and turn, keeping the process for the next
message. Startup or protocol failures reclaim the process, so the next send can resume.

`codex_app_server.lua` translates text deltas, reasoning, tool items, cumulative token
usage and terminal status into the shared renderer's events. An agentMessage completion
is displayed only when no deltas were received, preventing duplicate output. Failed and
interrupted terminal statuses are failed responses even though the process remains alive.

MCP, developer instructions, model, effort, compaction and sandbox settings are process
config overrides. Changed overrides cause the pool to replace the process and resume
the thread. The existing PreToolUse hook remains the approval and diff-baseline route. Codex
app-server does **not** inherit exec's `--dangerously-bypass-hook-trust`: a root CLI
flag is accepted but ignored for this subcommand (Codex 0.159.2). Before inference,
`hooks/list` must report the staged script as enabled and `trusted` or `managed`.
For an untrusted or modified hook, vibing.nvim matches the exact session-flag
PreToolUse command it staged, then uses Codex's `config/batchWrite` trust route with
that hook's reported key and current hash. It lists hooks again before starting a
thread. Missing hooks, mismatched commands, and writes that do not result in trust
produce an actionable error and reclaim the process. The startup error includes a
shell-quoted CLI command with the exact hook override for manual review through
`/hooks`. This check is intentionally part of startup, not an assumption based on argv.
Native app-server approval requests are declined; unsupported server requests receive
a JSON-RPC error and a visible notice rather than leaving Codex blocked. Native approval
and user-input dialogs are not implemented by this transport.

Verification: adapter tests exercise two turns on one process, resume, early/foreign
notifications, interrupt, failures, native request denial and replacement races. The
local Codex app-server was probed without inference for initialization and hooks/list.
Real model latency and full native approval UI parity have not been measured.
