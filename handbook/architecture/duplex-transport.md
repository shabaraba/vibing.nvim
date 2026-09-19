# The Duplex Transport: one resident CLI process per chat

Opt-in, claude only, default off. Turn it on with `backends.claude.process = "duplex"` or a chat's
own `process: duplex` frontmatter. Why it exists, what it cost, and the five things that had to move
before it could work at all.

Chats that can never use it, whatever the configuration says: a lightweight call (title generation,
`/summarize`), a subagent chat, and every backend other than claude. `process_model.lua` is the one
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

## What had to move

### 1. `Vibing.CanonicalEvent` had no "the turn is over"

The renderer's arms covered text, tools, usage, errors — everything a turn _contains_, nothing about
its end, because the process exiting had always said that. A successful `result` line produced no
event at all (`claude_stream_json` emitted one only for `subtype == "error"`).

So `result` now always emits `{ kind = "turn_end" }`, after the `error` arm it may also emit, and
`event_renderer` has a `turn_end` handler that calls `context.onTurnEnd` if one is set. The oneshot
path never sets one, so the event is decoded and dropped there. That ordering is load-bearing: a
turn the CLI declared failed has to have reached `resultErrors` before anything completes on it.

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

## What is deliberately not here

- **Approval and `AskUserQuestion` still kill the process.** `permission.lua`'s `cancel_and_deny`
  relies on `cancel` running `wrapped_on_done` synchronously and on the process being gone
  afterwards, which is what makes the approval's retry message a _new_ turn. Turning that into a
  `control_response` on the open stdin is #778. The user-facing cancel is the only path routed
  through the new `stop_turn`, which sends `control_request {subtype: "interrupt"}` and keeps the
  process; the CLI answers with a `result` of subtype `error_during_execution` and serves the next
  turn normally.
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
