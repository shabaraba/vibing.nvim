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

### Every withheld response is owed, and by whom

`rpc/pending_approvals.lua` holds one entry per withheld `.res` and guarantees each is written
exactly once. The four exits are the whole contract; a fifth would be a CLI hanging inside its own
hook until the script's deadline.

| exit                  | written by                             | reached from                                                  |
| --------------------- | -------------------------------------- | ------------------------------------------------------------- |
| the human answers     | `permission.release_answered_approval` | `ChatBuffer:_answer_pending_approval`, on `<CR>`              |
| the wait limit passes | the entry's own timer → `expire`       | armed by `open`; `on_timeout` tells the chat                  |
| the chat goes away    | `resolve_for_chat`                     | the chat's `BufUnload` cleanup, **before** it cancels the CLI |
| Neovim exits          | `resolve_all`                          | `VimLeavePre`, **before** the CLI is cancelled                |

The turn being stopped rather than answered — `:VibingCancel`, or typing a new message instead of
answering — reaches the third row too, through `ChatBuffer:cancel_request` and **before**
`stop_turn`.

Those "before"s are one fact stated three times: a killed CLI can no longer be the thing that stops
waiting, so the release has to happen while the process is still alive. `tests/lua/shutdown_spec.lua`,
`tests/lua/presentation/chat/view_approval_release_spec.lua` and the cancel cases in
`approval_prompts_spec.lua` pin each ordering.

**Reaching the limit denies one tool call and kills nothing.** Hooks run concurrently, so the user
is quite likely answering a different prompt of the same turn when this one expires; killing would
take the turn they are in the middle of. The hook exits 2, the model sees that one refusal, and the
turn carries on.

**Expiry denies the call, not the permission.** The question this feature was first asked was
"what if the user is away for half a day?", and past `approval_wait_sec` the honest answer has to
stay as good as the kill design's: there, the prompt outlived the turn and answering it any time
later retried the work. So an expired prompt keeps its option lines and is still spendable — what
changes is only how the answer travels. The registry entry is gone, so
`ChatBuffer:_answer_pending_approval` finds no blocked hook and routes it to `retry_as_new_turn`,
which is byte-for-byte the kill path. Refusing to spend it — the first shape of this — made waiting
**worse than today for exactly the absence it was meant to survive**, by taking away the user's
chance to grant the permission at all.

"Do not answer an expired prompt in place" is the part that is real, and **it is satisfied by
ordering rather than by a check**: `expire` calls `resolve` — which drops the registry entry —
before `on_timeout` marks the chat's copy expired, so no window exists in which a prompt is expired
and still registered. `_answer_pending_approval` then finds no blocked entry and has nowhere to
route it. A delegated answer is the one place that still refuses, and only while the target chat is
running: answering starts a new turn there, and that would cancel what it is doing.

**An invariant implemented twice ends up with one copy too wide.** That is the whole shape of this
mistake and it is worth keeping: `consume`'s check said the same thing the ordering already said,
except the check keyed on "expired" where the structure keys on "a hook is waiting". Those coincide
for the in-place route and diverge for the retry route, so the redundant copy silently took the
retry route with it — and the retry route was the user's only way back. The surviving test asserts
the property (`never sends an expired answer toward a hook`) rather than either implementation of
it, so the next person may move the guarantee without having to keep a particular `if`.

The wait limit also changes what the retry message may claim. The ordinary wording is written for a
turn that stopped _at_ the prompt, where nothing has happened since; after expiry the call was
denied and the model carried on, possibly finishing another way, so "proceed with the same
operation" can ask for work that is already done. `retry_message` takes `expired` and states the
grant instead of instructing. **Neither wording's effect on a model is measured** — what is known
without measuring is only that the original one says something false on this path.

## Why not answering `can_use_tool`

**What was measured is the round trip, not the argv that switched it on.** This section used to be
titled "Why not `--permission-prompt-tool stdio`", and that title was read later as evidence that
the flag had been passed with that value — it is not; the body below only ever claimed the
mechanism. The probe's script was not kept, so **which argv produced these events is not recorded**.
What the claude 2.1.236 binary's own strings say about it, as a hypothesis and not as evidence:

- `--permission-prompt-tool <tool>` normally names an **MCP tool** — `permissionPromptToolServerName`,
  and three errors of the form `tool … (passed via --permission-prompt-tool) must be an MCP tool`.
- `stdio` sits immediately next to `--permission-prompt-tool` in the string table, which is
  consistent with it being a recognised special value meaning "ask over the stream-json control
  channel" rather than through a server.
- The two are alternatives, and the CLI says so: `canUseTool callback cannot be used with
permissionPromptToolName. Please use one or the other.`

So there are two shapes with the same name attached to them, and they differ in what they need:
answering over the control channel needs `--input-format stream-json` — which
`backends/claude.lua` passes **only on the duplex transport**, and oneshot is the default
(`process_model.lua`) — while an MCP tool needs no control channel at all.

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

That inner object is recorded; **the envelope it travelled in is not**, and neither is the argv. A
re-run therefore has to discover the envelope again, and has to be able to tell "the CLI never
asked" apart from "the CLI asked and rejected our answer" — the binary has a distinct path for the
second (`Ignoring can_use_tool control_response for request_id=…`, and a
`permission_response_malformed` marker), so the difference is observable if the harness looks for
it rather than only for whether the tool ran.

**It was rejected anyway, because the prompt tool sits at the _end_ of the CLI's own gate.**
Measured: with `--allowedTools Write`, `can_use_tool` is **never called** — and it is not called for
a `Bash(echo …)` either, which the CLI's own safe-command classifier allows first. Routing vibing's
`ask` decisions through it would mean the user's own `settings.json` allow rules, and a
classifier we do not control, silently outvote vibing's `permissions.ask` list. There is no guard
available from inside that path: we are simply not asked.

The PreToolUse hook runs _before_ the gate, so the waiting design has no such hole. It is also
backend-neutral — nothing about it is claude-specific — where `--permission-prompt-tool` is.

#### The third shape, built and then removed

A narrower use of the same channel survived that rejection for a while and was implemented:
**release the approved call with `defer`, then answer the gate's own question** when it comes back.
The gate's veto is not a hole there, because a `defer` invites exactly that veto — steps 1 and 3
have both had their say before step 4 is reached, and re-running `can_use_tool` at step 4 would
only find the `:once` grant the human just spent already consumed. So step 4 could answer `allow`
with no second opinion, and the wait stayed where it was measured: in the hook, against claude's
1090s floor, rather than on a control-channel timeout nobody has timed.

It was removed once the control cell above showed a hook `allow` is equally safe, because **reach**
is what was left to decide on:

|                  | option B | third shape |
| ---------------- | -------- | ----------- |
| claude / duplex  | yes      | yes         |
| claude / oneshot | yes      | **no**      |
| copilot          | yes      | **no**      |

`stdio` means "ask over the control channel", which needs `--input-format stream-json`, which is
duplex-only — and oneshot is the default every chat gets. The third shape therefore left #778
switched off unless a user opted into a resident process, and withdrew it from copilot altogether
despite its 1700s floor being ample. An approval-without-kill that does not apply by default does
not answer the issue.

Worth restoring if the channel is wanted for its own sake: answering at step 4 puts the human's
approval **after** the user's granular rules rather than before them, which is a better ordering
than `allow` can offer. It would need to be acceptable as a duplex-only feature, and it would need
a measurement of how long the **control channel** tolerates a wait — `measured_wait_floor_sec`
times the hook, not the channel, and substituting one for the other is the mistake this page
records twice already. The reverted implementation is commit `e84ecf9e`, and the revert's own
message lists the three things in it that are expensive to rediscover.

### There is no free way to find out whether the flag value is accepted

The flag is still a live question for decision 1, so `permission_prompt_tool.sh` has to establish
the argv it was never recorded with. It opened with a pre-flight that was believed to cost nothing:
with `--input-format stream-json` and stdin at EOF there is no user message, so no request is sent,
and only the CLI's own argv validation runs. **That check could not fail.** Measured on claude
2.1.236 with three values — `stdio`, `mcp__probe__approve`, and a deliberate
`bogus_value_negative_control`:

| invocation          | all three values                                                             |
| ------------------- | ---------------------------------------------------------------------------- |
| without `--verbose` | exit 1, `When using --print, --output-format=stream-json requires --verbose` |
| with `--verbose`    | exit 0, **empty stderr and empty stdout** — not even a `system/init` line    |

The first row is why the check reported success: the error never names the flag, so the pre-flight's
`grep` for `permission-prompt-tool` matched nothing and it printed "accepted at startup" — **for the
bogus value too**. It did not fail to reject; it accepted everything.

Adding `--verbose` does not revive it, and **the empty stdout is what settles that**. "No rejection
message" alone would still read two ways, but a run that does not emit even `system/init` has exited
before session init — and the prompt tool is resolved at or after session init. So the pre-flight is
not mis-written, it is structurally unable to reach the code that would reject a value. The only
place `--permission-prompt-tool`'s argument is validated is inside a real turn.

`--help` cannot answer it either: the flag is undocumented in 2.1.236, and `--help` short-circuits
before option validation, so a bogus flag exits 0 there as well.

**The negative control is the whole reason this is known rather than suspected**, which is the same
lesson as "Register the reading before the run" below, applied one step earlier — to the check that
decides whether the run is needed at all. A cheap check that cannot fail is worse than no check: it
would have reported both hypotheses confirmed, for free, before a single token was spent. The
harness now carries the control as a cell on the same code path, run when — and only when — the arm
reports it was never consulted, which is the one outcome a rejected value and a gate that decided
first both produce.

### What the run measured, and the invariant it disproved

Run on claude 2.1.236, arm A, 2026-09-18, $0.18. Two cells.

**The allow cell re-established both missing records.** `--permission-prompt-tool stdio` is a real
value and is accepted; `control_request{subtype:"can_use_tool"}` arrived for `Write`; the **first**
candidate envelope was the one acted on:

```json
{ "type": "control_response",
  "response": { "subtype": "success", "request_id": "…", "response": { "behavior": "allow", "updatedInput": {…} } } }
```

So the argv and the envelope that the earlier probe failed to keep are recorded again — this time
in a committed script, with the raw logs under `.vibing/probe/permission-prompt-tool/`.

**The deny cell disproved the invariant it was written to test.** With
`permissions.deny: ["Write"]`, `Write` never reached the hook or the consultation. The model's own
`tool_result` reads:

> `Error: No such tool available: Write. Write is disabled for this session, in subagents as well as here.`

**A tool-name-level deny is applied when the toolset is built — upstream of the PreToolUse hook and
of any consultation.** An `allow` written into the `.res` therefore _cannot_ override it: the
question is never put to us. The sentence in `.claude/rules/architecture.md` and in this file — "an
`allow` skips the CLI's own gate, and with it the user's `settings.json` deny rules" — is wrong for
tool-level deny. (`.claude/` is not writable from here; the correction is an item on #779.)

Two limits on that sentence, neither measured away:

1. **The deny arrived through `--settings`, with `--setting-sources project`.** A `user`-scope deny
   was not loaded in this run. The conclusion is about _where in the pipeline_ a deny is applied,
   and sources merge before that point — but that merge is inferred here, not observed. Closing it
   means writing to the real `~/.claude/settings.json`, which the probe refuses to do.
2. **Granular rules (`Bash(rm -rf:*)`) are untouched by this.** They cannot be resolved at
   toolset-construction time, since they depend on one call's arguments. `default_deny_rules` and
   `destructive_commands.lua` live exactly there. So B's risk is **narrowed** to granular rules —
   and the next section measures it there too, and finds none.

### Granular deny runs before the consultation — and outranks a hook `allow`

The sentence above leaves B's risk narrowed to granular rules and unmeasured within them. Two more
cells settled it (claude 2.1.236, 2026-09-18, logs in `granular-control/` and `granular-ask/`).

**The command is not free to choose, and the obvious design walks into a trap this file already
records.** `can_use_tool` is not called for a `Bash(echo …)` — the CLI's safe-command classifier
allows it first — so a cell using a bare `echo` returns "never consulted" for a reason unrelated to
the deny rule, which reads exactly like "the granular deny ran first". The cells use
`echo "ok" > probe-out.txt`, whose consultation with no granular rule present was already logged by
arm A's deny cell. The redirect takes it out of the safe-command path.

**And the control cannot be "the same cell without the prompt tool".** With `Bash` outside
`--allowedTools` and nobody able to approve it, the refusal is unattributable. So G0 puts `Bash`
**in** `--allowedTools`, which makes a refusal the rule's doing and also shows the rule outranking
an explicit allow.

| cell                                            | called | hook | consulted | succeeded |
| ----------------------------------------------- | ------ | ---- | --------- | --------- |
| G0 — `--allowedTools Bash`, no prompt tool      | 1      | 1    | **0**     | 0         |
| G1 — `--allowedTools Read`, prompt tool `stdio` | 1      | 1    | **0**     | 0         |

Both returned the same `tool_result`:
`Permission to use Bash with command echo "ok" > probe-out.txt has been denied.`

The pre-registered mapping for that row was "not consulted + refused → the granular deny runs
first; the third shape is safe", and that is the outcome. Combining both arms gives the order:

```
1. toolset construction  — a tool-NAME deny removes the tool entirely
2. PreToolUse hook       — runs, and may defer          (HOOK DEFER fired in both cells)
3. granular deny rules   — evaluated here
4. can_use_tool          — reached only if 3 permits    (arm A's allow cell proves it is reached)
```

**So the third shape preserves every layer of the user's own settings**: it answers at step 4, and
step 4 is only reached by calls that already survived steps 1 and 3. Nothing it can say reaches a
deny rule, because a denied call never gets that far. That was the argument for building it, and it
is sound; what it turned out not to be is _exclusive_.

**That does not settle option B, and the two must not be run together.** There are two different
`allow`s here and they sit on opposite sides of step 3:

|                        | written at                       | is it consulted?         | vs. granular deny |
| ---------------------- | -------------------------------- | ------------------------ | ----------------- |
| third shape's `allow`  | step 4, answering `can_use_tool` | only for surviving calls | cannot reach it   |
| **option B's `allow`** | **step 2, in the hook's `.res`** | **every call**           | **see below**     |

`HOOK DEFER Bash` fired in both granular cells, and that is the proof that the hook _is_ asked, and
asked **before** step 3. Option B writes its `allow` exactly there. So "an `allow` cannot be offered
where nothing asks" is true of step 4 and false of step 2 — an earlier version of this paragraph
used the first to license the second, which is the same collapse-two-things-sharing-a-name mistake
as reading Bash's hook line as Write's.

Neither granular cell measured it, because `defer-hook.sh` always defers: both took the defer path.
The open question was:

> When the hook writes `allow`, is the step-3 granular deny skipped?

The order table **suggested it is skipped**, since the decision is rendered upstream of step 3, and
that suggestion was wrong. Two more cells settled it. Each differs from `granular-control` in
exactly one variable, and the probe's hook emits claude's own shape,
`{"hookSpecificOutput":{"permissionDecision":"allow"}}` — the same thing `bin/hooks/pre-tool-use.sh`
writes — so it exercises the mechanism production uses rather than a look-alike.

| cell                          | hook writes | `--allowedTools` | deny           | result                     |
| ----------------------------- | ----------- | ---------------- | -------------- | -------------------------- |
| `granular-control`            | `defer`     | `Bash`           | `Bash(echo:*)` | refused                    |
| `granular-hook-allow`         | `allow`     | `Bash`           | `Bash(echo:*)` | refused                    |
| `granular-hook-allow-control` | `allow`     | **`Read`**       | **`[]`**       | **ran** (`is_error=false`) |

The third row is the one that makes the second mean anything. `Bash` is not in its `--allowedTools`
and nothing else permits it, so the only thing that could have run it is our `allow` — **the hook's
`allow` is parsed and honoured.** The same `allow`, with one variable changed, then loses to
`Bash(echo:*)`. So:

> **A hook `allow` overrides the CLI's allowlist. It does not override its denylist.**

That is the answer to decision 1. B's cost is not the user's deny rules — a tool-name deny is out of
reach at step 1, a granular deny outranks the verdict at step 3 — it is only the allowlist, which by
construction could not have named the tool being approved. With the safety difference gone, reach
decides, and B reaches the default transport and a second backend where the third shape reaches
neither (see "Why not answering `can_use_tool`").

**`granular-hook-allow` was run accidentally, before its control existed.** A command meant to test
the arm's refusal path ran the arm instead (`OUT=… bash …` does not reach a script that recomputes
`OUT` from its own location). How a number was obtained is part of the number, and for a while this
one could not be read at all: refused, with no control, is the same single observation with two
possible authors as the 950s copilot cell — the `allow` was honoured and the deny beat it, or the
`allow` was never honoured. Its logs are in `granular-hook-allow/`.

```
hook.log     HOOK ALLOW Bash
driver.log   ATTEMPTED Bash {"command":"echo \"ok\" > probe-out.txt"}
             TOOL_RESULT is_error=true
               Permission to use Bash with command echo "ok" > probe-out.txt has been denied.
```

`HOOK ALLOW Bash` proves our script ran and printed; it says nothing about whether the CLI parsed
it. The prior was good — the envelope is copied from `bin/hooks/pre-tool-use.sh`, which emits
exactly this for claude and demonstrably allows tools in production — but that is a different
configuration (vibing's generated settings, not `--settings` inline), which raises a prior without
closing it. The control is what closed it, and **the accidental cell is not retroactively made
sound by its control arriving later**: it was unreadable when it was run, and the reason to say so
is that the next person deciding whether a cell is worth paying for needs the order of operations,
not just the pair.

Two unmeasured assumptions remain, stated rather than closed:

1. **The deny arrived through `--settings`, with `--setting-sources project`.** A `user`-scope deny
   was not loaded in either granular cell — the same limit as the tool-name result above, and for
   the same reason: closing it means writing to the real `~/.claude/settings.json`.
2. **The ordering may depend on _which_ command the rule names.** `echo` was used because it is
   harmless while `Bash(rm -rf:*)` is the rule under real concern. Nothing here rules out a
   classifier treating a destructive command differently — though it would have to do so by
   refusing more readily, which is the safe direction for B.

What this does not settle: the third shape needs `--permission-prompt-tool stdio`, hence
`--input-format stream-json`, which `backends/claude.lua` passes **only on the duplex transport**
while oneshot is the default. Arm B — the MCP-tool form, which needs no control channel — is the
question of whether the same shape reaches oneshot. Its precondition, "worth a turn only if the
deny runs before the consultation", is now **met**. It has not been run.

### A cell is not an observation of a tool

The deny cell's summary said the opposite of its log, and the design principle the harness was
built on is what hid it. "Three signals, never collapsed into one verdict" was implemented, and it
was not enough: each signal was counted **per cell** while the reading table meant **per tool**.
Write was denied, the model fell back to `Bash`, and every count then described `Bash` — the hook
had fired, we had been consulted, `probe-out.txt` existed. Printed verdict: _"we were consulted and
our allow decided the outcome"_, which the pre-registered table maps to **decision 1 is B**. The
correct reading survived only because someone read the raw log instead of the summary.

The axis that mattered was not signal-into-signal but **tool-into-cell**. Separating signals is
worthless while each one aggregates over whichever tools the model happened to try, and a
filesystem effect — the probe file whose existence this document once called "the verdict" — names
no author at all.

Two further readings were wrong on the way to fixing it, both the same shape one level down:

- **A zero from an instrument that was not installed is not a zero.** Scoping the signals made the
  _allow_ cell report "measurement failed — the model never called Write", because its log predates
  the `ATTEMPTED` lines. Absence of the instrument now prints `?` and is tracked separately from
  absence of the event.
- **Being consulted proves the call was made**, so consultation has to be tested before the attempt
  count. Ordering it the other way produced the reading above.

The first of those has now appeared **three times**, which is what makes it a type rather than an
incident. The third was caught before it could mislead anybody: `report()` counted `HOOK DEFER`
only, so the hook-`allow` cells — the ones that settled decision 1 — would have printed "the hook
never saw it" for a hook that saw it and allowed it. Its instrument, `grep -c 'HOOK DEFER'`, was
not installed for the thing being measured. It now counts both verdicts and prints which. Each of
the three has the same tell: a count that _cannot go up_ in the configuration it is being read in.
Worth asking of any zero before believing it.

The harness now carries `self-test` (four crafted logs, no tokens) and `report-only <dir>`, which
re-reads a saved cell. `report-only` is what makes a corrected _reading_ distinguishable from a
corrected _measurement_: it holds the log fixed. All three defects are mutation-tested — each
mutant restores the wrong reading and is caught by a different self-test case, which is the check
that the cases are not passing vacuously.

### A test that passes for a reason you have not written down

Third of the same family, and the one that is hardest to notice because nothing is red.

The reverted third shape prefiltered stdout with a substring test (`line:find('"can_use_tool"')`)
before paying for a JSON decode, and a test asserted that ordinary prose mentioning the subtype
passes through to the decoder untouched. It passed. It passed because **JSON escapes quotes**: the
same characters inside a string value arrive as `\"can_use_tool\"` and do not contain the unescaped
needle. That sentence was nowhere in the test, so what the test actually pinned was the outcome,
not the mechanism — and an encoder change, or a prefilter rewritten without quotes in the needle,
would have broken the safety property while the test went on passing.

The general form: **a prefilter is a stand-in for a structural test, and it is only sound while the
property that makes it equivalent holds.** If that property is not named in the test, the test does
not defend it. The fix is not a stronger assertion on the same observation — it is to assert the
_property_ (here, that encoding produces the escaped form) so that losing it fails something.

Related but distinct from the equivalent mutant in the same commit, which is the honest opposite
case: a line of code no test can distinguish, recorded as such rather than defended with a
contrived test. One is a test claiming more than it checks; the other is a test that cannot exist.
Both are worth writing down; only the first is a defect.

## The ordering invariant, and why every backend needs it

Three numbers, in three different files and two languages, that must stay in this order:

```
permissions.approval_wait_sec  <  pre-tool-use.sh's own wait  <  <backend>'s configured hook timeout
```

**Both CLIs measured fail OPEN when their configured hook timeout expires: the tool runs with no
verdict at all.** This was not obvious, and two earlier readings of it were wrong — see
"How this was measured wrong twice" below.

The invariant makes that unreachable, twice over:

1. vibing's own wait limit expires first, and the fallback writes `deny` into the `.res`. The hook
   returns a verdict and exits normally.
2. If that never happens — Neovim crashed, the RPC server died, the timer was never armed — the
   hook script reaches its own deadline and **exits 2 on its own** (`# Timeout - fail closed`).

Only something outside our control (the hook process being SIGKILLed) can reach the CLI's timeout.

`copilot_settings_generator.lua` already stated half of this — "`HOOK_TIMEOUT_SEC` … has to stay
comfortably above [the script's wait] or a slow approval would turn into a silent allow" — and
attributed it to copilot's fail-open behaviour. The measurement below shows the same hole in claude,
where `settings_generator.lua`'s `timeout = 120` and the script's own 120s were **equal**, with no
margin at all — a present-tense bug, independent of #778, which is why it was fixed on its own
(`fix(hooks): give claude's hook timeout a margin over the script's own deadline`).

Being right about one backend was never the problem; being right about one backend _only_ was.
`copilot_settings_generator_spec.lua` was the sole place the ordering was checked, so claude, codex
and grok were free to drift. The check now runs per descriptor over `agents.lua`
(`hook_timeout_ordering_spec.lua`), and each transport reports the timeout it registers rather than
the spec re-deriving each generator's schema — claude's `timeout`, copilot's `timeoutSec`, codex's
`-c` TOML fragment, grok's delegation to claude's generator. A transport that cannot answer fails
the spec, because "no timeout reported" and "an unsafe timeout" are indistinguishable from outside.

## Measurements

claude 2.1.236, copilot 1.0.83 (the 950s re-run: 1.0.85), macOS. Reproduce with
`VIBING_PERF=1 tests/perf/hook_wait_ceiling.sh <backend> <block_sec> <configured_timeout_sec> [mode] [gate_preallowed]`.

**Two of the rows below predate that script and were produced by an ad-hoc `.vibing/probe/hook.sh`,
which logged the same events under different names** — `HOOK FINISHED NORMALLY` where the committed
reproducer says `HOOK REACHED ITS OWN BUDGET`, and `SIGTERM after Ns` where it says
`CUT BY SIGTERM after Ns`. The two hooks are otherwise behaviourally identical (same 10s heartbeat,
same three traps, same budget, same `exit 0`), so the numbers are comparable. Grepping a fresh run
for a string quoted here is not: **the quotes below are verbatim from the logs that produced the
numbers, not from what a re-run emits.**

### How long a hook may block

Configured timeout set to 1800s; the hook blocks and heartbeats every 10s.

**Every number here is a floor, and the column that says why is not decoration.** Two runs ending
at different numbers usually means two runs watched for different lengths of time, so the table
records _who stopped it_ next to each one. Read without that column, "claude 1090 / copilot 1700"
says copilot is the more patient CLI, which is not something either run measured.

| backend | blocked for | who stopped it                                            | ceiling      |
| ------- | ----------- | --------------------------------------------------------- | ------------ |
| claude  | **1090s**   | **we did** — SIGTERM from our own job stop, at 1090s      | not establd. |
| copilot | **1700s**   | **nobody** — the hook completed its own 1700s budget      | not establd. |
| codex   | —           | **not measured** (usage limit)                            | —            |
| grok    | —           | **not measured** (not signed in on the measuring machine) | —            |

Both runs were configured with a 1700s budget against an 1800s timeout. copilot's reached the end
of it (`HOOK FINISHED NORMALLY after 1700s`); claude's was killed at 1090s when the harness was
stopped, so nothing was learned about claude past 1090 — and in particular **not** that claude is
less patient than copilot.

A separate 950s copilot run confirms the same thing independently
(`HOOK REACHED ITS OWN BUDGET after 950s without being cut`, copilot 1.0.85). That run also logs
`VERDICT: the tool did not run`, which is **copilot's gate refusing a tool it had no rule for**, not
the hook's verdict — `mode=default` with the gate not pre-allowed is exactly the confound described
in "How this was measured wrong twice". The only thing that cell says about the hook is that it
blocked for 950s, was not cut, and exited 0.

An earlier copilot run was reported as **670s** and read as a shorter ceiling. It was neither: the
log was read while the run was still going. That reading was enough to motivate a whole design —
clamping the wait per backend — which is the failure this column exists to prevent.

The 120s vibing configured before this work was **not** a CLI limit. It was a value we chose, and
both CLIs honour a much larger one — which is what makes the 930s the default now derives possible
at all.

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
call** — and answering one leaves the other spinning to the script's own deadline. The invariant above means
copilot never times out in normal operation, but the fallback path can still reach this, so it is
handled rather than assumed away.

**Both prompts are shown, and that is deliberate.** Collapsing them by matching `(tool, input)` is
the obvious move and it is wrong: a model calling the same tool twice with the same input is
legitimate, and since hooks run concurrently the two can be **in flight at the same time** — so the
rule would silently refuse a second call that nobody asked about. Detecting the orphan properly is
not available either: nothing tells us a hook died, so any such rule is a guess, and a wrong guess
here denies a call the user never saw.

**What the decision costs, measured as a test rather than assumed** (`approval_prompts_spec.lua`,
"keeps holding while another prompt is still open"): the orphan's registry entry outlives every
answer the user gives, so the output hold stays on after the real prompt is answered. The user
still sees output at each answer — `add_user_section` flushes on the way — but the turn's **tail**
arrives only when the turn ends, where `_finish_turn` releases the orphan and flushes. Late, not
lost. Making output arrive late is the safe side of this trade; denying a tool call on a guess is
not.

### copilot: an _errored_ hook is not a _timed-out_ hook

A hook that exits non-zero for its own reasons is refused — `Denied by preToolUse hook … (hook
errored)` — where a hook that times out is allowed through. Two different code paths. Do not
generalise either one into "copilot is safe" or "copilot is unsafe".

### How long the CLI waits for an MCP tool — a fourth deadline, measured at 1800s

A different ceiling, and `nvim_ask_user_question` sits on it: that tool never goes through
PreToolUse, so none of the three numbers above apply to it. Against a stub MCP server that never
answers, claude ran to the end and said so:

```text
MCP server "probe" tool "wait_forever" sent no response or progress for 1800s; aborting.
```

**1800 seconds, on claude. Measured.** codex and grok are not measured here either.

Everything else in that message — a per-server `timeout` in milliseconds, a global
`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`, `0` to disable — is **the CLI describing itself, which is a
hypothesis and not evidence** (the same shape as the binary string in "How this was measured wrong
twice"). None of it was tried, and two of the three could not be reached from here anyway:
`cli_mcp_config.spec()` carries `command` / `args` / `env` only, it emits nothing at all unless
`agent.mcp.user_servers = false`, and on the normal path vibing's server arrives through
`--plugin-dir` reading `claude-plugin/.claude-plugin/plugin.json`. Raising the ceiling would mean
writing a `timeout` into two places and trusting a claim.

It does not need raising. `approval_wait_sec` plus its margins is **990s against a measured 1800**,
so the ticket-and-poll design for `nvim_ask_user_question` fits inside the deadline as it ships.
What that costs instead is one more thing to keep ordered, so
`hook_timeout_ordering_spec.lua` asserts the whole derived budget stays under 1800 — a user raising
`approval_wait_sec` past it would otherwise get a silent 30-minute hang.

**Two different things are called "progress" here, and they point opposite ways.** The message means
MCP `notifications/progress`, sent **by an MCP server to the CLI**; `tool_progress` is a stream
event the **CLI sends us**. Our MCP server implements neither, so "just send progress to reset the
timer" describes machinery that does not exist on our side.

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
1090 is where the harness was stopped and copilot's 1700 is where the hook's own budget ran out,
and **neither log contains a CLI deciding anything**. Clamping to a floor bakes a measurement
artifact into the product and leaves "why is claude shorter?" with no answer — a question that had
already been asked the other way round, about copilot, from a number read off a running log.

What the floors _are_ good for is checking the invariant's precondition, and that check is not
optional: if the script's deadline exceeds what a CLI will actually wait, that CLI's timeout fires
and the table above says the tool then runs ungated. So every backend the feature is enabled for
needs a measured floor above the script's deadline — not a guess that it is probably fine.

### The derivation, and where it currently stands

`wait_budget.lua` turns the one configured number into the three:

```text
approval_wait_sec            900   what the user configures (floored at 30)
  + SCRIPT_MARGIN_SEC  30 =  930   pre-tool-use.sh's own deadline
  + CLI_MARGIN_SEC     60 =  990   what every backend registers as its hook timeout
```

The margins are sized by what each one covers, not by taste. The script's 30s is slack for the
fallback timer's deny to be written and land — it is a backstop for "Neovim answered the RPC and
then wrote nothing", which is our own bug, since a dead RPC server already fails closed on `nc -w 1`
and a dead Neovim takes its CLI children with it. The CLI's 60s covers everything before the poll
loop starts counting (process spawn, `cat` of stdin, the `nc` round trip) and is the larger of the
two because being wrong there fails _open_ where being wrong in the script fails closed.

The script's deadline travels in the child's environment (`VIBING_HOOK_MAX_WAIT_SEC`), since
`pre-tool-use.sh` is one fixed file shared by every chat. Its env-absent fallback is **60s, not
930** — deliberately below the smallest timeout the derivation can produce (30 + 30 + 60 = 120), so
that a user who _lowers_ `approval_wait_sec` does not end up with a script outlasting the timeouts
it lowered. A resident duplex process is handed its environment once at spawn, so a changed setting
reaches it on the next process rather than the next turn.

Against the measured floors, with the default 900:

| backend | measured floor | script deadline 930 inside it? |
| ------- | -------------- | ------------------------------ |
| claude  | 1090s          | yes                            |
| copilot | 1700s          | yes                            |
| codex   | not measured   | **no — feature stays off**     |
| grok    | not measured   | **no — feature stays off**     |

"Not measured" is not "probably fine": those two keep today's `cancel_and_deny` behaviour until
somebody runs `tests/perf/hook_wait_ceiling.sh` against them. The ordering itself is asserted for
all four in `tests/lua/infrastructure/hooks/hook_timeout_ordering_spec.lua`, because a backend that
does not wait still registers a timeout and still must not be the one to give up first.

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

### Register the reading before the run

Every mistake on this page has the same shape from the outside: a number or an outcome was produced
first and interpreted afterwards, and the interpretation fitted whatever had appeared. 670 / 950 /
1700 were read off logs, "the tool did not run" was read off a cell with two possible authors, and
52 / 384 were read off whatever the last command happened to print.

So the harnesses here print **what was measured and, separately, what it means** — and the mapping
from one to the other is written into the script before it is ever run.
`tests/perf/permission_prompt_tool.sh` is the clearest case: it reports three signals
(did the hook fire, was the prompt tool called, did the tool run) and then prints one of four
pre-registered readings. Two of those four look identical in a single verdict and answer the
question in opposite directions, which is exactly the confusion that made the 950s cell wrong.

The cost is a few lines. What it buys is that a surprising result stays surprising instead of
becoming the reading you would have chosen for it.

And one wrong inference from a source that looked authoritative: the claude binary contains
`"PreToolUse hook did not respond before its timeout … The tool call was not executed"`, which was
read as proof of fail-closed. It continues `(host client may be unreachable)` — it belongs to the
remote hook-forwarding path, not to a local command hook. **A string in the binary is a hypothesis;
only the measurement is evidence.**

### Keep the instrument, not just the number

Three numbers on this page were produced by tooling that was not kept, and each went unnoticed until
somebody tried to use it:

- the **verbatim `control_request`** above — the probe's script was not kept, so the argv that
  elicited it is unrecorded, and re-establishing it is now a whole harness
  (`tests/perf/permission_prompt_tool.sh`) rather than a re-run.
- the **1090s / 1700s** rows — produced by an ad-hoc `.vibing/probe/hook.sh`, not by the
  `hook_wait_ceiling.sh` this page names as the reproducer, and logging the same events under
  different strings. Quoting one and naming the other makes a re-run look like it failed.
- the PR's **46 mutations** — the appliers lived in `/tmp`; they and their inputs were rescued into
  `.vibing/probe/mutations/` before a reboot would have taken them. Eight of the 46 had already
  lost both, having been applied as inline heredocs that never existed as files.

The pattern is not carelessness about logs — **the logs were all kept.** It is that a measurement's
evidence is treated as its output, when the thing that decays is the _instrument_. A number whose
instrument is gone cannot be re-run, only re-measured, and a re-measurement is a new result that
happens to be compared against an old one.

This compounds with the corollary above: a reproducer is the cheapest claim on a page to check —
run it — so it is the one nobody checks, and it rots silently. **If a number is worth recording,
commit the thing that produced it**, or say in the same breath that it is unreproducible.

**An instrument is not the same thing as its script.** The mutation rescue had to be done three
times before it was real: the scripts alone raised `FileNotFoundError`, because each reads its
pre-mutation source from a snapshot beside it rather than from the live file; copying the snapshots
too still left the scripts pointing at `/tmp`, which fails only _later_, and until then reads
whatever happens to be at that path. A tool's inputs, and the paths it resolves them by, are part
of it. **The test of a rescue is running the thing, not counting the files** — the version that
finally worked was confirmed by applying one mutation to a scratch copy and checking it removed
what it claims to.

And the snapshots decay in a second way that nothing warns about: they are the source **as of the
run**, so a stale one silently reverts the file it is written over. Four of the nine surviving
inputs still match HEAD; the rest differ by up to 238 lines. That asymmetry is the whole reason to
record staleness next to a preserved instrument rather than just its existence — and to report it
per input, because **a set of inputs is only as fresh as its oldest member.** One series here writes
four files at once and three of its four snapshots match HEAD exactly, which buys nothing: the
fourth went stale when later work touched that file, so running it reverts 35 lines whatever the
other three say. Summarising those four numbers as "current" is the same collapse as reading a cell
with two possible authors as one answer.

**Preserving an instrument can remove the accident that was protecting you.** While the snapshots
sat in `/tmp`, a stale run was going to become a `FileNotFoundError` the next time the OS cleared
it — and that looked like a reason to leave them there. It is not a safety property: it depends on
when an unrelated process runs, it does nothing in the window before that, and it fires just as
readily on the snapshots that are still correct. The fix is not to preserve the accident but to
make the dangerous operation check itself, so `_guard.py` now compares each snapshot against the
file it would overwrite and refuses, by name and with the drift. **A safety property that nothing
states and nothing tests is a coincidence**, and moving files is enough to end it.

The guard's first draft reported ~1312 changed lines where `diff` says 207, because it compared
positionally and an insertion near the top shifts everything after it. Worth recording only because
of where it happened: an error message overstating the damage, inside the check written to stop a
number from being wrong. Most of the errors collected on this page make things look **better** than
they are — 52/384, "accepted at startup", a reproducer that does not reproduce. This one overstates,
from the same mechanism, which is worth knowing when deciding how much to trust a surprising number
in either direction.

**And the guard was verified against the wrong thing first.** The check was exercised by calling
`require_current` directly and watching it allow two series and refuse three — which tests the
function, not the scripts. One script writes both production files unconditionally _before_
deciding what to do, so the guard sat after the damage there: `restore` never reached it, and an
applied mutation printed `REFUSED` with 318 lines already reverted. Testing a component in place of
the path it sits in is how a guard passes review while protecting nothing.

Two attempts at the replacement test then passed **vacuously** — a shell quoting slip meant the
scripts never ran, and the second one printed "production files BYTE-IDENTICAL", which is exactly
what a working guard prints. What settled it was a **positive control**: forcing the guard off and
confirming the files really do change by 318 lines. A verification that cannot distinguish "the
guard held" from "nothing executed" is the same defect as the pre-flight at the top of this page,
found the same way.

**What actually saved these was an audit, not a handover.** The location of the scripts was never
written down; `/tmp` came up only because the numbers they produced were being re-derived and
somebody went looking for the cost of re-running them. So "write down where the tool is" is the
wrong lesson to take from this — nobody who had the tool thought of it as something to keep. The
lesson is the one above: **when a number is recorded, its instrument is part of the record**, and
the moment to act on that is when the number is written, not when it is questioned.
