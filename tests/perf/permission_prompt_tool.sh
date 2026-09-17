#!/bin/bash
# Can a PreToolUse hook that says `defer` hand the final decision back to us, and does the user's
# own settings.json deny still apply on the way? (#778, decision 1)
#
# Run with:
#   VIBING_PERF=1 tests/perf/permission_prompt_tool.sh            # arm A (the default)
#   VIBING_PERF=1 tests/perf/permission_prompt_tool.sh stdio      # arm A only
#   VIBING_PERF=1 tests/perf/permission_prompt_tool.sh mcp        # arm B only
#   VIBING_PERF=1 tests/perf/permission_prompt_tool.sh both       # both, unconditionally
#
# **This spends real tokens**, so the arms are separate commands rather than one run: **arm B is
# worth a turn only if arm A shows the user's `settings.json` deny running BEFORE the consultation.**
# If it does not, the third shape is dead there and then — it is B wearing C's clothes — and
# measuring the same mechanism through its other entrance cannot change an ordering. Run arm A, read
# its deny cell, and only then decide about arm B.
#
# Arm B is the one worth having if it is available: oneshot is the default transport and arm A needs
# `--input-format stream-json`, so an arm-A-only result makes the third shape duplex-only and leaves
# the product with two behaviours to keep straight.
#
# Cells are conditional and **say so when they are skipped**, because a silently omitted cell reads
# as one that passed. Per arm: the `allow` cell always runs; `deny` runs only if `allow` was
# consulted; the negative control runs only if it was not.
#
# What is being decided. An approval answered in place has to end as a verdict the CLI acts on, and
# the `.res` file carries three of them:
#
#   B — write `allow`. The hook prints it and the CLI **skips its own gate**, so this one call also
#       skips the user's own `settings.json` deny rules, which `--setting-sources` still loads.
#   C — write `defer`. The gate runs, but the just-approved tool is not in this turn's
#       `--allowedTools` (that is *why* it was asked about) and the argv cannot change mid-turn, so
#       in headless mode the gate has nobody to ask and the call the human just approved is refused.
#
# A third shape would have both properties — defer, let the gate run, and answer the gate's own
# question. **The mechanism for that is not hypothetical**: `handbook/architecture/approval-without-kill.md`
# records a verbatim `control_request{subtype: "can_use_tool"}` from claude 2.1.236, with `allow`
# running the tool and the process staying alive. What that record does *not* contain is the argv
# that switched it on or the envelope the answer travelled in, because the probe's script was not
# kept. So this harness re-establishes both, and then asks the question that was never asked.
#
# **Two arms, because they are two different mechanisms with one name**, and which one works decides
# whether the third shape is available at all:
#
#   A. `--permission-prompt-tool stdio` — ask over the stream-json control channel. It needs
#      `--input-format stream-json`, which `backends/claude.lua` passes **only on the duplex
#      transport** while oneshot is the default — so if only this arm works, the third shape is
#      duplex-only.
#   B. `--permission-prompt-tool mcp__<server>__<tool>` — ask an MCP tool. The binary's own errors
#      say the argument must be an MCP tool, and it carries a server name
#      (`permissionPromptToolServerName`), so this is the ordinary form. It needs no control
#      channel, so it would work on both transports.
#
# **Neither arm's argv is verified.** What differs is only what sits behind it: arm A's answer goes
# into a round trip that was measured end to end (the recorded `control_request`, with `allow`
# running the tool), while arm B's whole path is untried. That `stdio` is the value which reaches
# that round trip is a hypothesis from the binary's string table, exactly like arm B's. Only a real
# turn can settle it — see "no free pre-flight" below.
#
# Arm A is first because of what is behind it, not because its flag is any better established. Arm
# B is the one we would rather have, since oneshot is the default transport.
#
# The verdict is the probe file on disk, never what the CLI says about itself: `probe-out.txt`
# exists iff the Write ran.
set -u

if [ "${VIBING_PERF:-}" != "1" ]; then
  echo "tests/perf/permission_prompt_tool.sh spends real tokens; set VIBING_PERF=1 to run it." >&2
  exit 0
fi

ARM="${1:-stdio}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/.vibing/probe/permission-prompt-tool"
mkdir -p "$OUT"

# --- There is no free pre-flight. Measured, with a negative control. --------------------------
#
# This script used to open by running the CLI with `--input-format stream-json` and stdin at EOF, on
# the reasoning that no user message means no request, so argv validation runs for free and a bad
# value fails loudly. **That check could not fail.** Run against claude 2.1.236 with three values —
# `stdio`, `mcp__probe__approve`, and `bogus_value_negative_control` — all three behaved identically:
#
#   without --verbose:  exit 1, "When using --print, --output-format=stream-json requires --verbose"
#                       for all three. The error never mentions the flag, so the old grep matched
#                       nothing and the function returned "accepted at startup" — **for the bogus
#                       value too.**
#   with --verbose:     exit 0, empty stderr, and **empty stdout** for all three. Not even a
#                       `system/init` line is emitted.
#
# Empty stdout is the part that settles it: on EOF the CLI exits before session init, and the prompt
# tool is resolved at or after session init. So the free check is not merely mis-written — it is
# structurally unable to reach the code that would reject a value. Adding `--verbose` does not
# revive it.
#
# The negative control is why this is known rather than suspected, and it is kept below as a cell
# rather than deleted: the only place the flag value can be validated is inside a real turn.
#
# `--help` cannot answer it either — the flag is undocumented in 2.1.236 and `--help` short-circuits
# before option validation, so a bogus flag also exits 0 there.

# The value used for the negative-control cell. It must be one no CLI could ever honour, so that any
# difference between it and a real arm is attributable to the value.
BOGUS_VALUE="bogus_value_negative_control"

# Exit 0 in silence is `defer` in vibing's own vocabulary and "no opinion" in the CLI's: the hook
# permits the call and leaves the gate in charge, which is exactly the state an in-place approval
# would be in under C.
cat > "$OUT/defer-hook.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
echo "$(date +%s) HOOK DEFER" >> "$HOOK_LOG"
exit 0
EOF
chmod +x "$OUT/defer-hook.sh"

# ---------------------------------------------------------------------------------------------
# Arm A driver: speak the stream-json control protocol.
#
# **The envelope is the unknown here, so the driver reports what happened to its answer rather than
# assuming it landed.** The binary has a distinct path for a rejected one
# (`Ignoring can_use_tool control_response for request_id=`, `permission_response_malformed`), so
# "we answered and it was ignored" is observable — and it is a completely different result from
# "the CLI never asked". Conflating those two is the confound that made the 950s copilot cell wrong.
#
# It tries the envelope shapes in order and records which one, if any, the CLI acted on.
# ---------------------------------------------------------------------------------------------
cat > "$OUT/stdio_driver.mjs" <<'EOF'
import { spawn } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const LOG = process.env.DRIVER_LOG;
const log = (m) => appendFileSync(LOG, `${Math.floor(Date.now() / 1000)} ${m}\n`);

const args = JSON.parse(process.env.CLAUDE_ARGS);
const child = spawn('claude', args, { cwd: process.env.PROBE_CWD, stdio: ['pipe', 'pipe', 'pipe'] });

child.stderr.on('data', (d) => log(`STDERR ${d.toString().trim()}`));

// One user message, then nothing: the turn is what we are measuring.
child.stdin.write(
  JSON.stringify({
    type: 'user',
    message: {
      role: 'user',
      content: 'Use the Write tool to create probe-out.txt containing exactly: ok. Then stop.',
    },
  }) + '\n'
);

// Candidate envelopes, most likely first. Each `can_use_tool` request gets the next untried one, so
// a run with several requests walks the list; a run with one request tries one. Which one was
// accepted is the thing to read off the log.
const envelopes = [
  (id, payload) => ({ type: 'control_response', response: { subtype: 'success', request_id: id, response: payload } }),
  (id, payload) => ({ type: 'control_response', request_id: id, response: payload }),
  (id, payload) => ({ type: 'control_response', response: { request_id: id, ...payload } }),
];
let nextEnvelope = 0;

createInterface({ input: child.stdout }).on('line', (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    log(`UNPARSEABLE ${line.slice(0, 200)}`);
    return;
  }

  if (msg.type === 'control_request' && msg.request?.subtype === 'can_use_tool') {
    // Verbatim, because the shape is the record this run exists to re-establish.
    log(`ASKED ${JSON.stringify(msg)}`);
    const shape = envelopes[Math.min(nextEnvelope, envelopes.length - 1)];
    const used = nextEnvelope;
    nextEnvelope += 1;
    const answer = shape(msg.request_id, { behavior: 'allow', updatedInput: msg.request.input ?? {} });
    log(`ANSWERED envelope=${used} ${JSON.stringify(answer)}`);
    child.stdin.write(JSON.stringify(answer) + '\n');
    return;
  }

  if (msg.type === 'result') {
    log(`RESULT ${JSON.stringify(msg).slice(0, 400)}`);
    child.stdin.end();
  }
});

// A hard deadline, because the whole subject of this probe is a CLI that may sit waiting for an
// answer it never recognises. Without it a rejected envelope reads as a hung terminal rather than
// as a result, and the run has to be killed by hand — which is how the ceiling table got a number
// that recorded when someone stopped watching.
const deadlineMs = Number(process.env.DRIVER_TIMEOUT_SEC ?? 180) * 1000;
const watchdog = setTimeout(() => {
  log(`DRIVER TIMEOUT after ${deadlineMs / 1000}s -- killing the CLI. This is us stopping it, not the CLI deciding anything.`);
  child.kill('SIGTERM');
  setTimeout(() => process.exit(0), 2000);
}, deadlineMs);

child.on('close', (code) => {
  clearTimeout(watchdog);
  log(`CLI EXIT ${code}`);
  process.exit(0);
});
EOF

# ---------------------------------------------------------------------------------------------
# Arm B server: one MCP tool that logs every call and always allows.
#
# Always-allow is right for the measurement: what is being asked is *whether we are consulted*, and
# a deny would confuse "the CLI never asked" with "the CLI asked and we said no".
# ---------------------------------------------------------------------------------------------
cat > "$OUT/prompt_server.mjs" <<'EOF'
import { createInterface } from 'node:readline';
import { appendFileSync } from 'node:fs';

const LOG = process.env.PROMPT_TOOL_LOG;
const log = (m) => appendFileSync(LOG, `${Math.floor(Date.now() / 1000)} ${m}\n`);
const send = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');

const TOOL = {
  name: 'approve',
  description: 'Permission prompt tool for the probe.',
  inputSchema: {
    type: 'object',
    properties: { tool_name: { type: 'string' }, input: { type: 'object' } },
  },
};

createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return;
  let req;
  try {
    req = JSON.parse(line);
  } catch {
    return;
  }
  if (req.method === 'initialize') {
    send({
      jsonrpc: '2.0',
      id: req.id,
      result: {
        protocolVersion: '2024-11-05',
        capabilities: { tools: {} },
        serverInfo: { name: 'probe', version: '0.0.0' },
      },
    });
    return;
  }
  if (req.method === 'tools/list') {
    send({ jsonrpc: '2.0', id: req.id, result: { tools: [TOOL] } });
    return;
  }
  if (req.method === 'tools/call') {
    log(`CALLED ${JSON.stringify(req.params ?? {})}`);
    send({
      jsonrpc: '2.0',
      id: req.id,
      result: {
        content: [
          {
            type: 'text',
            text: JSON.stringify({ behavior: 'allow', updatedInput: req.params?.arguments?.input ?? {} }),
          },
        ],
      },
    });
    return;
  }
  if (req.id !== undefined) send({ jsonrpc: '2.0', id: req.id, result: {} });
});
EOF

settings_for() {
  cat <<EOF
{"permissions":{"deny":$1},
 "hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"HOOK_LOG=$HOOK_LOG bash $OUT/defer-hook.sh","timeout":60}]}]}}
EOF
}

# **Three signals, reported separately and never collapsed into one verdict.** "Nobody asked us AND
# the tool did not run" and "we were asked, and the call was refused afterwards" are different facts
# with the same-looking outcome, and reading one as the other is the confound that produced a wrong
# reading of the 950s copilot cell. Signal 1 is the control: without it the other two say nothing,
# because the hook never ran. Signal 2 splits further on arm A, where being asked and having the
# answer accepted are also two different things.
report() {
  local dir="$1" asked="$2"
  local hook_fired tool_ran
  hook_fired=$(grep -c 'HOOK DEFER' "$HOOK_LOG" || true)
  if [ -f "$dir/probe-out.txt" ]; then tool_ran=yes; else tool_ran=no; fi

  echo "1. hook wrote defer:      $hook_fired"
  echo "2. we were consulted:     $asked"
  echo "3. tool ran:              $tool_ran"

  # Nothing below is a measurement; it is the mapping decided before the run, printed next to what
  # was measured, so a surprising result cannot be re-read into the reading one would have chosen.
  if [ "$hook_fired" -eq 0 ]; then
    echo "   READING: measurement failed -- the hook never ran, so 2 and 3 are about something else."
  elif [ "$asked" -eq 0 ]; then
    echo "   READING: the gate settled it before consulting us. Whatever decided it ran FIRST."
  elif [ "$tool_ran" = "no" ]; then
    echo "   READING: we WERE consulted and the call was still refused afterwards. On arm A this may"
    echo "            also mean the envelope was wrong -- check the log for ASKED/ANSWERED and for"
    echo "            'Ignoring can_use_tool control_response'."
  else
    echo "   READING: we were consulted and our allow decided the outcome."
  fi
  echo "logs: $dir"
}

# The flag value is a parameter rather than a literal, so the negative control travels the *same*
# code path as the real arm. A control that differs in any other way answers a different question.
run_stdio_cell() {
  local name="$1" deny="$2" value="${3:-stdio}"
  local dir="$OUT/stdio-$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  export HOOK_LOG="$dir/hook.log" DRIVER_LOG="$dir/driver.log" PROBE_CWD="$dir"
  export DRIVER_TIMEOUT_SEC="${DRIVER_TIMEOUT_SEC:-180}"
  : > "$HOOK_LOG"
  : > "$DRIVER_LOG"

  local settings
  settings=$(settings_for "$deny")
  export CLAUDE_ARGS
  CLAUDE_ARGS=$(cat <<EOF
["-p","--input-format","stream-json","--output-format","stream-json","--verbose",
 "--model","claude-haiku-4-5-20251001","--permission-mode","default",
 "--strict-mcp-config","--setting-sources","project",
 "--permission-prompt-tool","$value","--allowedTools","Read",
 "--settings",$(printf '%s' "$settings" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]
EOF
)
  echo "=== arm A (control channel), cell $name (--permission-prompt-tool $value, settings deny: $deny) ==="
  node "$OUT/stdio_driver.mjs"
  report "$dir" "$(grep -c 'ASKED' "$DRIVER_LOG" || true)"
}

run_mcp_cell() {
  local name="$1" deny="$2" value="${3:-mcp__probe__approve}"
  local dir="$OUT/mcp-$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  export HOOK_LOG="$dir/hook.log" PROMPT_TOOL_LOG="$dir/prompt-tool.log"
  : > "$HOOK_LOG"
  : > "$PROMPT_TOOL_LOG"

  local settings mcp
  settings=$(settings_for "$deny")
  mcp=$(cat <<EOF
{"mcpServers":{"probe":{"command":"node","args":["$OUT/prompt_server.mjs"],"env":{"PROMPT_TOOL_LOG":"$PROMPT_TOOL_LOG"}}}}
EOF
)
  echo "=== arm B (MCP tool), cell $name (--permission-prompt-tool $value, settings deny: $deny) ==="
  ( cd "$dir" && claude -p \
      --output-format stream-json --verbose \
      --model claude-haiku-4-5-20251001 \
      --permission-mode default \
      --strict-mcp-config --setting-sources project \
      --mcp-config "$mcp" \
      --permission-prompt-tool "$value" \
      --allowedTools "Read" \
      --settings "$settings" \
      "Use the Write tool to create probe-out.txt containing exactly: ok. Then stop." \
      > "$dir/stream.jsonl" 2>"$dir/stderr.log" )
  echo "CLI exit=$?"
  report "$dir" "$(grep -c 'CALLED' "$PROMPT_TOOL_LOG" || true)"
}

# The negative control, and **when it is worth a turn**.
#
# It is only needed for one of the three outcomes. If the arm reports `consulted > 0`, the flag value
# reached the mechanism and there is nothing left to control for. If it reports `consulted = 0`, that
# has two possible authors — the gate settled it first, or **the value was never a value** and the
# flag was inert — and those are the two the old pre-flight was supposed to separate. So the control
# runs exactly then, and says so either way rather than being silently skipped.
maybe_negative_control() {
  local arm="$1" consulted="$2"
  if [ "$consulted" -gt 0 ]; then
    echo "NEGATIVE CONTROL: not run -- arm $arm was consulted, so the value demonstrably reached the"
    echo "                  mechanism and there is nothing for a control to separate."
    return 0
  fi
  echo "NEGATIVE CONTROL: running -- arm $arm was never consulted, which a rejected/ignored flag"
  echo "                  value and a gate that decided first both produce."
  case "$arm" in
    A) run_stdio_cell control "[]" "$BOGUS_VALUE" ;;
    B) run_mcp_cell control "[]" "$BOGUS_VALUE" ;;
  esac
  echo "   READING: if this control cell looks IDENTICAL to the real cell above, the flag value"
  echo "            changed nothing and the arm is unproven -- not refuted by the gate."
  echo "            If the CLI rejected this value but accepted the real one, the real value is"
  echo "            recognised and the gate genuinely decided first."
}

# Cell "allow": nothing in the user's deny list. Expect hook=1, consulted, the tool ran. Anything
# else means the combination does not work on that arm.
#
# Cell "deny": the user denies Write. What the readings mean for decision 1:
#
#   consulted=0            -> the deny ran first. **The third shape is safe**: deferring keeps the
#                             user's settings.json rules, and only what survives them reaches us.
#   consulted, no run      -> we are asked before the deny is applied. Safe here only because
#                             something else refused it; what an allow does in general needs its own
#                             run. On arm A, also check the envelope first.
#   consulted, tool ran    -> our allow overrode the user's own deny. The third shape is B with
#                             extra steps, and decision 1 is B.
if [ "$ARM" = "stdio" ] || [ "$ARM" = "both" ]; then
  run_stdio_cell allow "[]"
  consulted_a=$(grep -c 'ASKED' "$OUT/stdio-allow/driver.log" || true)
  # The "allow" cell decides whether the "deny" cell can say anything. Its question is "does our
  # answer reach the mechanism at all"; the deny cell's question presupposes that it does.
  if [ "$consulted_a" -gt 0 ]; then
    run_stdio_cell deny '["Write"]'
  else
    echo "SKIPPED: arm A cell 'deny' -- the allow cell was never consulted, so a deny cell could"
    echo "         only re-measure that. Run it once the allow cell is consulted."
  fi
  maybe_negative_control A "$consulted_a"
fi

if [ "$ARM" = "mcp" ] || [ "$ARM" = "both" ]; then
  run_mcp_cell allow "[]"
  consulted_b=$(grep -c 'CALLED' "$OUT/mcp-allow/prompt-tool.log" || true)
  if [ "$consulted_b" -gt 0 ]; then
    run_mcp_cell deny '["Write"]'
  else
    echo "SKIPPED: arm B cell 'deny' -- the allow cell was never consulted, so a deny cell could"
    echo "         only re-measure that. Run it once the allow cell is consulted."
  fi
  maybe_negative_control B "$consulted_b"
fi

exit 0
