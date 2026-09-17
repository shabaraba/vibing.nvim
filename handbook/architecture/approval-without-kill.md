# Answering an approval without killing the CLI

What a tool-approval prompt costs today is the whole turn: `permission.lua` kills the process, the
hook denies, and the user's answer comes back as a _new_ turn carrying a synthesized
"I approved the X tool..." message. #778 removes the kill. This file is why the shape it takes is
the one it is, and the measurements the numbers come from.

Identifier background is `processes-and-turns.md`; the resident transport is `duplex-transport.md`.

## The mechanism: the hook already knew how to wait

`bin/hooks/pre-tool-use.sh` writes a `<request_id>.req`, pokes the RPC server with `nc -w 1`
(fire-and-forget — the RPC reply is _not_ the decision), and then **polls for `<request_id>.res`**.
The decision travels as a file, not as the RPC response, which means the hook can already block for
as long as the `.res` is withheld. Today it never blocks, only because `cancel_and_deny` writes the
deny immediately.

So "answer in place" is not a new transport. It is: **stop writing the `.res` until the human
answers.** The CLI sits inside its own hook; nothing is killed; the turn continues afterwards.

## Why not `--permission-prompt-tool stdio`

The issue's original design was to answer the CLI's `control_request {subtype: "can_use_tool"}`
with a `control_response`. It works — measured, verbatim, against claude 2.1.236:

```json
{
  "type": "control_request",
  "request_id": "2b3badea-…",
  "request": {
    "subtype": "can_use_tool",
    "tool_name": "Write",
    "display_name": "Write",
    "input": { "file_path": "…/probe-output.txt", "content": "hello-from-probe" },
    "description": "probe-output.txt",
    "permission_suggestions": [
      { "type": "setMode", "mode": "acceptEdits", "destination": "session" }
    ],
    "tool_use_id": "toolu_01Q1uQRPQvUKJtJLG5QEqsbo"
  }
}
```

Answering `{"behavior":"allow","updatedInput":{…}}` ran the tool and the turn completed with the
process alive; answering `{"behavior":"deny","message":"…"}` reached the model as a `tool_result`
with `is_error: true`, recorded one entry in `result.permission_denials`, and the turn carried on
and answered normally. The synthesized retry message is genuinely unnecessary on that path.

**It was rejected anyway, because the prompt tool sits at the _end_ of the CLI's own gate.**
Measured: with `--allowedTools Write`, `can_use_tool` is **never called** — and it is not called for
a `Bash(echo …)` either, which the CLI's own safe-command classifier allows first. Routing vibing's
`ask` decisions through it would mean the user's own `settings.json` allow rules, and a
classifier we do not control, silently outvote vibing's `permissions.ask` list. There is no guard
available from inside that path: we are simply not asked.

The PreToolUse hook runs _before_ the gate, so the waiting design has no such hole. It is also
backend-neutral — nothing about it is claude-specific — where `--permission-prompt-tool` is.

## The ordering invariant, and why every backend needs it

Three numbers, in three different files, that must stay in this order:

```
permissions.approval_wait_sec  <  pre-tool-use.sh MAX_WAIT  <  <backend>'s configured hook timeout
```

**Both CLIs measured fail OPEN when their configured hook timeout expires: the tool runs with no
verdict at all.** This was not obvious, and two earlier readings of it were wrong — see
"How this was measured wrong twice" below.

The invariant makes that unreachable, twice over:

1. vibing's own wait limit expires first, and the fallback writes `deny` into the `.res`. The hook
   returns a verdict and exits normally.
2. If that never happens — Neovim crashed, the RPC server died, the timer was never armed — the
   hook script reaches its own `MAX_WAIT` and **exits 2 on its own** (`# Timeout - fail closed`).

Only something outside our control (the hook process being SIGKILLed) can reach the CLI's timeout.

`copilot_settings_generator.lua` already stated half of this — "`HOOK_TIMEOUT_SEC` … has to stay
comfortably above [MAX_WAIT] or a slow approval would turn into a silent allow" — and attributed it
to copilot's fail-open behaviour. The measurement below shows the same hole in claude, where
`settings_generator.lua`'s `timeout = 120` and `MAX_WAIT`'s 120s are **equal**, with no margin at
all. That is a present-tense bug, independent of #778.

## Measurements

claude 2.1.236, copilot 1.0.83, macOS. Reproduce with
`VIBING_PERF=1 tests/perf/hook_wait_ceiling.sh <backend> <block_sec> <configured_timeout_sec> [mode] [gate_preallowed]`.

### How long a hook may block

Configured timeout set to 1800s; the hook blocks and heartbeats every 10s.

| backend | blocked for | outcome                                                            |
| ------- | ----------- | ------------------------------------------------------------------ |
| claude  | **1080s**   | still alive when the run was stopped; true ceiling not established |
| copilot | **670s**    | still alive when the run was stopped; true ceiling not established |
| codex   | —           | **not measured** (usage limit)                                     |
| grok    | —           | **not measured** (not signed in on the measuring machine)          |

Both numbers are floors, not ceilings, and both were stopped deliberately: establishing a real
ceiling costs the ceiling in wall-clock, and no decision here needs one.

The 120s vibing configures today is **not** a CLI limit. It is a value we chose, and a larger one
is honoured.

### What expiry does

Block 150s against a 30s configured timeout, so the timeout is certainly reached.

| backend | permission mode   | CLI gate pre-allows the tool | tool ran?                                |
| ------- | ----------------- | ---------------------------- | ---------------------------------------- |
| claude  | default           | no                           | no — **the gate's deny, not the hook's** |
| claude  | default           | yes                          | **yes — fail open**                      |
| claude  | bypassPermissions | no                           | **yes — fail open**                      |
| copilot | default           | no                           | no — the gate's deny                     |
| copilot | default           | yes                          | **yes — fail open**                      |
| copilot | bypassPermissions | no                           | **yes — fail open**                      |

The hook fires in every cell, including the pre-allowed ones — so `--allowedTools` covering a tool
does **not** skip PreToolUse. (`HOOK START` in the log is the proof; it is not assumed.)

### copilot retries a timed-out hook

copilot ran the hook **twice** in every expiry cell. A retry is a _new_ `.req` with a new
`request_id`, so a design that withholds the `.res` can produce **two approval prompts for one tool
call** — and answering one leaves the other spinning to `MAX_WAIT`. The invariant above means
copilot never times out in normal operation, but the fallback path can still reach this, so it is
handled rather than assumed away.

### copilot: an _errored_ hook is not a _timed-out_ hook

A hook that exits non-zero for its own reasons is refused — `Denied by preToolUse hook … (hook
errored)` — where a hook that times out is allowed through. Two different code paths. Do not
generalise either one into "copilot is safe" or "copilot is unsafe".

### How long the CLI waits for an MCP tool

A different ceiling, and `nvim_ask_user_question` sits on it: that tool never goes through
PreToolUse, so the hook timeout does not apply to it. Against a stub MCP server that never answers,
claude waited **480s and counting**, emitting a `tool_progress` heartbeat every 30s with
`elapsed_time_seconds` counting up. A long MCP response is a case the CLI has explicit machinery
for, not an anomaly it tolerates — which is what makes waiting there a supported shape rather than
a gamble.

`tool_progress` has no `by_type` handler in `decoders/claude_stream_json.lua`, so it is decoded and
dropped, which is the documented behaviour for an unknown type. Worth remembering as material: it
is the event that could render "waiting for approval, 1 minute" without any polling of our own.

## Where 900 seconds comes from

`permissions.approval_wait_sec` defaults to **900** (15 minutes). The reason is _not_ that the
measured floors are above it — **the ceiling is a constraint, not a justification**, and a future
CLI raising it is not a reason to raise this.

The reason is what the number is for. Half-day absences are not meant to be waited out; they are
what the fallback exists for, and the fallback is byte-for-byte today's behaviour. So the limit only
has to cover "the user stepped away and is coming back", and every second beyond that is paid for:

- **the prompt cache TTL is 55/60 minutes** (`token_usage.DEFAULT_CACHE_TTL_SEC`,
  `prefix_rewrite.CACHE_TTL_SECONDS`). A wait that crosses it re-pays the whole prefix on resume.
- **a resident process is ~200MB of RSS** held for the duration (`duplex-transport.md`).

15 minutes is comfortably inside both — which is a check that the choice is _possible_, not the
argument for it.

**One value, for every backend.** A per-backend limit derived from the floors above would be
recording how long each run happened to be watched, not a difference between the CLIs: claude's
1080 and copilot's 670 differ because the runs were stopped at different times, and nothing in
either log says the CLI was the one that stopped. Clamping to a floor bakes a measurement artifact
into the product and leaves "why is copilot shorter?" with no answer.

What the floors _are_ good for is checking the invariant's precondition, and that check is not
optional: if `MAX_WAIT` exceeds what a CLI will actually wait, that CLI's timeout fires and the
table above says the tool then runs ungated. So every backend the feature is enabled for needs a
measured floor above `approval_wait_sec` plus `MAX_WAIT`'s margin — not a guess that it is probably
fine.

## How this was measured wrong twice

Both mistakes produced a plausible verdict rather than an error, which is the only reason they were
worth the second look. Recorded because the harness now controls for them and someone re-measuring
should know what the controls are for.

1. **`bypassPermissions` was used "to isolate the hook".** It isolates the _gate_: that mode leaves
   nothing to refuse a tool whose hook timed out, so of course the tool runs. The reading "claude
   fails open" was true of that mode and said nothing about the mode real chats use.
2. **The gate, not the hook, was answering.** In headless `default` mode the gate has nobody to
   prompt, so it refuses a tool it has no rule for. "The tool did not run" was the gate's verdict;
   the hook's own behaviour only became visible once `--allowedTools Write` guaranteed the gate
   would say yes.

And one wrong inference from a source that looked authoritative: the claude binary contains
`"PreToolUse hook did not respond before its timeout … The tool call was not executed"`, which was
read as proof of fail-closed. It continues `(host client may be unreachable)` — it belongs to the
remote hook-forwarding path, not to a local command hook. **A string in the binary is a hypothesis;
only the measurement is evidence.**
