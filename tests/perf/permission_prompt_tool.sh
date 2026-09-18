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
# **The verdict is attributed to a named tool, never to an effect on disk.** This file used to say
# "the verdict is the probe file on disk … `probe-out.txt` exists iff the Write ran", and the deny
# cell disproved it on the first real run: Write was refused, the model fell back to Bash, Bash
# created `probe-out.txt`, and the file-existence check reported the tool under test as having run.
# A filesystem effect names no author. Every signal below is scoped to the tool being measured.
set -u

ARM="${1:-stdio}"

# `report-only` re-reads logs that already exist and spawns no CLI, so it is deliberately outside
# the token guard. It is how a past run gets re-read after the reading logic is corrected — which
# is not hypothetical: the deny cell's saved log was read three different ways by three versions of
# `report`, and only re-running them against the *same* log showed which reading changed.
if [ "$ARM" != "report-only" ] && [ "$ARM" != "self-test" ] && [ "${VIBING_PERF:-}" != "1" ]; then
  echo "tests/perf/permission_prompt_tool.sh spends real tokens; set VIBING_PERF=1 to run it." >&2
  echo "To re-read logs from an earlier run without spending anything:" >&2
  echo "  $0 report-only <cell-dir> [tool]   # tool defaults to Write" >&2
  exit 0
fi

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
# The PreToolUse payload names the tool, and `cat > /dev/null` threw that away. An unattributed
# DEFER line is unreadable in any cell where the model reaches for more than one tool: the count
# says "the hook fired", the reading table means "the hook fired *for Write*", and in the deny cell
# those were different tools. Keep the name.
payload=$(cat)
tool=$(printf '%s' "$payload" | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("tool_name") or "UNNAMED")
except Exception:
    print("UNPARSEABLE")' 2>/dev/null) || tool=UNPARSEABLE
echo "$(date +%s) HOOK DEFER ${tool:-UNPARSEABLE}" >> "$HOOK_LOG"
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
      content:
        process.env.PROBE_PROMPT ||
        'Use the Write tool to create probe-out.txt containing exactly: ok. Then stop.',
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

  // The deny cell's whole question is *where* the call died, and "nobody was consulted" has two
  // causes that look identical from the ASKED count alone: the deny ran first, or the model never
  // reached for the tool. Only the model's own tool_use and the tool_result it got back separate
  // them, so both are recorded. The first run of this probe logged neither and could not be read.
  if (msg.type === 'assistant') {
    for (const block of msg.message?.content ?? []) {
      if (block.type === 'tool_use') {
        log(`ATTEMPTED ${block.name} ${JSON.stringify(block.input).slice(0, 200)}`);
      }
    }
  }

  if (msg.type === 'user') {
    for (const block of msg.message?.content ?? []) {
      if (block.type === 'tool_result') {
        const body = typeof block.content === 'string' ? block.content : JSON.stringify(block.content);
        log(`TOOL_RESULT is_error=${block.is_error === true} ${String(body).slice(0, 300)}`);
      }
    }
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

# **Four signals, reported separately, and every one of them scoped to a named tool.**
#
# The original version kept the signals separate but counted each of them *per cell*, and the first
# real deny cell showed why that is not enough. Write was denied, the model fell back to Bash, and
# every cell-wide count then described Bash: the hook had fired (for Bash), we had been consulted
# (about Bash), and the probe file existed (written by Bash). The summary printed "we were consulted
# and our allow decided the outcome" -- which the reading table maps to "our allow overrode the
# user's deny, decision 1 is B" -- when the truth was that Write was never offered to anyone. The
# right answer survived only because the raw log was read instead of the summary.
#
# So the axis that mattered was not signal-into-signal but **tool-into-cell**: separating the
# signals is worthless while each one silently aggregates over whichever tools the model happened
# to try. A cell is not an observation of a tool.
report() {
  local dir="$1" tool="${2:-Write}"
  local drv="$dir/driver.log" hooklog="${HOOK_LOG:-$dir/hook.log}"
  local attempted asked hook_fired succeeded unattributed fallbacks

  attempted=$(awk -v t="$tool" '$2=="ATTEMPTED" && $3==t' "$drv" 2>/dev/null | wc -l | tr -d ' ')
  # Arm A records the consultation as ASKED in the driver log, arm B as CALLED in the prompt-tool
  # log. Both carry the tool name in the same key, so one scoped expression covers both arms --
  # deliberately, because a per-arm reading is how the two would drift into disagreeing about what
  # "we were consulted" means.
  asked=$( { grep ' ASKED ' "$drv" 2>/dev/null
             grep ' CALLED ' "$dir/prompt-tool.log" 2>/dev/null
           } | grep -c "\"tool_name\":\"$tool\"" || true)
  hook_fired=$(grep -c "HOOK DEFER $tool\$" "$hooklog" 2>/dev/null || true)
  # A DEFER line with no tool name comes from a log written before the hook recorded one. It cannot
  # be attributed after the fact, and guessing is the exact failure being fixed -- so it is counted
  # separately and reported as unusable rather than folded into signal 1.
  unattributed=$(grep -c 'HOOK DEFER$' "$hooklog" 2>/dev/null || true)
  # Pair each TOOL_RESULT with the ATTEMPTED immediately above it: the result line does not name
  # its tool, but it always follows its own call.
  succeeded=$(awk -v t="$tool" '
    $2=="ATTEMPTED"   { last=$3 }
    $2=="TOOL_RESULT" && last==t && $3=="is_error=false" { n++ }
    END { print n+0 }' "$drv" 2>/dev/null)
  fallbacks=$(awk -v t="$tool" '$2=="ATTEMPTED" && $3!=t {print $3}' "$drv" 2>/dev/null | sort -u | tr '\n' ' ')

  # **A zero from an instrument that was not installed is not a zero.** Cells recorded before
  # ATTEMPTED logging existed have no tool_use lines at all, and reading that as "the model never
  # called the tool" turns a cell that measured fine into a reported failure -- which is the same
  # mistake as reading Bash's DEFER as Write's, one level up. So absence of the instrument is
  # tracked separately from absence of the event.
  local has_attempt_log
  has_attempt_log=$(grep -c ' ATTEMPTED ' "$drv" 2>/dev/null || true)

  echo "tool under test:            $tool"
  if [ "$has_attempt_log" -eq 0 ]; then
    echo "0. model called it:         ? (log predates ATTEMPTED logging)"
  else
    echo "0. model called it:         $attempted"
  fi
  echo "1. hook wrote defer for it: $hook_fired"
  echo "2. we were consulted on it: $asked"
  echo "3. it succeeded:            $succeeded"
  echo "   other tools attempted:   ${fallbacks:-(none)}"

  if [ "$unattributed" -gt 0 ]; then
    echo "   WARNING: $unattributed 'HOOK DEFER' line(s) carry no tool name (log predates the fix)."
    echo "            Signal 1 above is therefore a floor, not a count. If it reads 0 while the"
    echo "            hook did fire, that 0 is 'unknown', and no ordering claim rests on it."
  fi
  if [ -n "$fallbacks" ]; then
    echo "   NOTE: the model reached for another tool in this cell. Any cell-wide count -- including"
    echo "         the existence of probe-out.txt -- describes that tool, not $tool."
  fi

  # Nothing below is a measurement; it is the mapping decided before the run, printed next to what
  # was measured, so a surprising result cannot be re-read into the reading one would have chosen.
  # Consultation is itself proof the model called the tool -- nobody is asked about a call that was
  # never made -- so it is tested before signal 0. Ordering these the other way is what made the
  # allow cell, whose log has no ATTEMPTED lines, report as a failed measurement.
  if [ "$asked" -gt 0 ] && [ "$succeeded" -gt 0 ]; then
    echo "   READING: we were consulted about $tool and our allow decided the outcome."
  elif [ "$asked" -gt 0 ] && [ "$has_attempt_log" -eq 0 ]; then
    echo "   READING: we were consulted about $tool, so it WAS called. Whether it then succeeded is"
    echo "            unknown from this log -- it predates tool_result logging. Check the cell for"
    echo "            the effect itself, and attribute it to a tool before believing it."
  elif [ "$asked" -gt 0 ]; then
    echo "   READING: we WERE consulted about $tool and the call was still refused afterwards. On"
    echo "            arm A this may also mean the envelope was wrong -- check the log for"
    echo "            ASKED/ANSWERED and for 'Ignoring can_use_tool control_response'."
  elif [ "$has_attempt_log" -eq 0 ]; then
    echo "   READING: unreadable -- we were not consulted, and this log predates ATTEMPTED logging,"
    echo "            so 'refused upstream of the hook' and 'the model never called $tool' cannot"
    echo "            be told apart. This is the ambiguity the ATTEMPTED lines were added for."
  elif [ "$attempted" -eq 0 ]; then
    echo "   READING: measurement failed -- the model never called $tool, so nothing here is about"
    echo "            ordering. Re-run; do not read this as a deny arriving first."
  elif [ "$hook_fired" -eq 0 ]; then
    echo "   READING: the model DID call $tool and neither the hook nor we ever saw it, so it was"
    echo "            refused UPSTREAM of both. Read its TOOL_RESULT for what refused it."
  else
    # asked=0, the model called it, and the hook did see it: the refusal sits between the two.
    echo "   READING: the hook saw $tool but the gate settled it without consulting us. Whatever"
    echo "            decided it ran after the hook and before the consultation."
  fi
  echo "logs: $dir"
}

# The reader has its own failure modes, and all three it has had so far were caught by feeding it a
# log rather than by running the CLI. Its input *is* a log file, so it can be tested for free.
#
# Case 2 is the one no archived cell reaches: the deny cell short-circuits at "never consulted" and
# the allow cell's log predates tool_result logging, so "consulted, then refused" existed only as a
# branch nobody had ever executed. Each case below is one that previously read wrong.
if [ "$ARM" = "self-test" ]; then
  t=$(mktemp -d); fails=0
  check() { # name, expected substring, dir
    local got; got=$(HOOK_LOG="$3/hook.log" report "$3" Write | grep -A3 READING)
    if printf '%s' "$got" | grep -q "$2"; then
      echo "ok   $1"
    else
      echo "FAIL $1 -- expected /$2/, got:"; printf '%s\n' "$got" | sed 's/^/       /'; fails=1
    fi
  }

  mkdir -p "$t/upstream"
  printf '1 ATTEMPTED Write {}\n1 TOOL_RESULT is_error=true No such tool available: Write.\n2 ATTEMPTED Bash {}\n2 ASKED {"request":{"tool_name":"Bash"}}\n2 TOOL_RESULT is_error=false\n' > "$t/upstream/driver.log"
  printf '2 HOOK DEFER Bash\n' > "$t/upstream/hook.log"
  echo ok > "$t/upstream/probe-out.txt"   # decoy: the effect exists, Bash made it
  check "denied upstream, model fell back to another tool" "refused UPSTREAM" "$t/upstream"

  mkdir -p "$t/refused"
  printf '1 ATTEMPTED Write {}\n1 ASKED {"request":{"tool_name":"Write"}}\n1 TOOL_RESULT is_error=true refused after consultation\n2 ATTEMPTED Bash {}\n2 TOOL_RESULT is_error=false\n' > "$t/refused/driver.log"
  printf '1 HOOK DEFER Write\n' > "$t/refused/hook.log"
  echo ok > "$t/refused/probe-out.txt"    # decoy again
  check "consulted, then refused anyway" "still refused afterwards" "$t/refused"

  mkdir -p "$t/allowed"
  printf '1 ATTEMPTED Write {}\n1 ASKED {"request":{"tool_name":"Write"}}\n1 TOOL_RESULT is_error=false\n' > "$t/allowed/driver.log"
  printf '1 HOOK DEFER Write\n' > "$t/allowed/hook.log"
  check "consulted and allowed" "our allow decided" "$t/allowed"

  mkdir -p "$t/legacy"
  printf '1 ASKED {"request":{"tool_name":"Write"}}\n' > "$t/legacy/driver.log"
  printf '1 HOOK DEFER\n' > "$t/legacy/hook.log"
  check "old log, consulted but no tool_use lines" "it WAS called" "$t/legacy"

  rm -rf "$t"
  [ "$fails" -eq 0 ] && echo "self-test passed" || echo "self-test FAILED"
  exit "$fails"
fi

# Re-read a saved cell. Spends nothing, so it sits outside the token guard -- and it is the only
# way to tell a corrected reading from a corrected measurement, since it holds the log fixed.
if [ "$ARM" = "report-only" ]; then
  target="${2:-}"
  if [ -z "$target" ] || [ ! -f "$target/driver.log" ]; then
    echo "usage: $0 report-only <cell-dir> [tool]" >&2
    echo "cells under $OUT:" >&2
    ls -1d "$OUT"/*/ 2>/dev/null >&2
    exit 1
  fi
  HOOK_LOG="$target/hook.log" report "$target" "${3:-Write}"
  exit 0
fi

# The flag value is a parameter rather than a literal, so the negative control travels the *same*
# code path as the real arm. A control that differs in any other way answers a different question.
run_stdio_cell() {
  local name="$1" deny="$2" value="${3:-stdio}"
  local dir="$OUT/stdio-$name"
  # Kept, not deleted. A re-run usually happens *because* the previous one read ambiguously, which
  # makes that log the reason the re-run exists; deleting it leaves only the answer one preferred.
  [ -d "$dir" ] && mv "$dir" "$dir-prev-$(date +%s)"
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
  # The consultation count is derived inside report(), scoped to the tool. Passing a cell-wide
  # count in from here is what let the deny cell's Bash consultation stand in for Write's.
  report "$dir" Write
}

run_mcp_cell() {
  local name="$1" deny="$2" value="${3:-mcp__probe__approve}"
  local dir="$OUT/mcp-$name"
  # Kept rather than deleted, for the same reason arm A keeps its cells: a re-run usually happens
  # because the previous one read ambiguously, which makes that log the reason the re-run exists.
  [ -d "$dir" ] && mv "$dir" "$dir-prev-$(date +%s)"
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
  # Arm B has no driver process, so the tool_use / tool_result blocks exist only in the raw stream.
  # Normalise them into the exact line format arm A's driver writes, so ONE report() reads both
  # arms. Without this, arm B has no way to attribute a signal to a tool at all -- which is the
  # defect that made arm A's deny cell unreadable, reintroduced on the other arm.
  python3 - "$dir/stream.jsonl" "$dir/driver.log" <<'PY'
import json, sys

src, dst = sys.argv[1], sys.argv[2]
lines = []
try:
    handle = open(src)
except OSError:
    handle = None
if handle:
    with handle as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            blocks = (msg.get("message") or {}).get("content") or []
            if msg.get("type") == "assistant":
                for b in blocks:
                    if b.get("type") == "tool_use":
                        lines.append("- ATTEMPTED %s %s" % (b.get("name"), json.dumps(b.get("input"))[:200]))
            elif msg.get("type") == "user":
                for b in blocks:
                    if b.get("type") == "tool_result":
                        body = b.get("content")
                        body = body if isinstance(body, str) else json.dumps(body)
                        flag = "true" if b.get("is_error") is True else "false"
                        lines.append("- TOOL_RESULT is_error=%s %s" % (flag, str(body)[:300]))
with open(dst, "w") as f:
    f.write("".join(l + "\n" for l in lines))
PY
  report "$dir" Write
}

# --- The granular arm: does our `allow` skip the user's per-call deny rules? -------------------
#
# Arm A settled tool-NAME-level deny: the tool is gone before anyone is asked, so an `allow` cannot
# reach it. That says nothing about **granular** rules (`Bash(echo:*)`, `Bash(rm -rf:*)`), which
# depend on one call's arguments and therefore cannot be resolved when the toolset is built. This
# is where `permissions.default_deny_rules` and destructive_commands.lua live, so it is the whole
# of B's remaining risk.
#
# Proposition, fixed before the run:
#
#   When we write `allow` for one call a human approved in place, is the user's own granular deny
#   rule skipped, or does it still apply?
#
# **The command is not free to choose, and this is the trap in the obvious design.** This file's own
# handbook section records that `can_use_tool` is *not* called for a `Bash(echo …)`, because the
# CLI's safe-command classifier allows it first. A cell using a bare `echo` would come back "never
# consulted" for a reason that has nothing to do with the deny rule, and that reads exactly like
# "the granular deny ran first" -- the wrong answer, arrived at confidently.
#
# So the command is `echo "ok" > probe-out.txt`, and the control for that confound is already
# bought: arm A's deny cell logged this exact command being consulted with no granular rule in
# place (stdio-deny/driver.log). The redirect takes it out of the safe-command path.
#
# **G0 is not "the same cell without the prompt tool".** That was the starting proposal and its
# control proves nothing: with Bash outside `--allowedTools` and no prompt tool, the call is refused
# because nobody can approve it, which is indistinguishable from being refused by the rule. So G0
# puts Bash **in** `--allowedTools`. Then a refusal is attributable to the rule alone, and it also
# shows the rule outranking an explicit allow.
#
#   G0 (control): --allowedTools Bash, deny ["Bash(echo:*)"], NO prompt tool
#       refused  -> the rule matches and beats the allow list. G1 is readable.
#       ran      -> the rule does not match at all. **G1 is unreadable**; fix the rule, re-run.
#
#   G1 (the question): --allowedTools Read, deny ["Bash(echo:*)"], --permission-prompt-tool stdio
#       consulted + succeeded  -> our allow OVERRODE the user's granular deny. Decision 1 is B,
#                                 and its cost is real and now measured.
#       not consulted + refused -> the granular deny runs FIRST. The third shape is safe.
#       consulted + refused     -> we were asked and the deny still won afterwards. Also safe, but
#                                 by a different mechanism than "deny first" -- record it as its
#                                 own outcome, do not merge it into the line above.
#       not consulted + succeeded -> contradiction: nothing permitted it. Invalid; investigate.
#
# Assumption stated rather than measured: that the ordering does not depend on **which** command the
# rule names. `echo` is used because it is harmless; the rule under real concern is
# `Bash(rm -rf:*)`. Nothing here rules out a classifier that treats a destructive command
# differently -- though it would have to do so by refusing *more* readily, which is the safe
# direction for the third shape and the unsafe one for B.
# --- WHAT THE GRANULAR CELLS MEASURED (claude 2.1.236, 2026-09-18) ----------------------------
#
# Recorded beneath the pre-registration, not over it. Both cells produced the SAME four signals,
# and the control is what makes that identity mean something rather than nothing:
#
#   G0 (control, --allowedTools Bash, no prompt tool):
#     called=1  hook=1  consulted=0  succeeded=0
#     tool_result: `Permission to use Bash with command echo "ok" > probe-out.txt has been denied.`
#     -> the rule matches, and it beats an explicit --allowedTools entry. G1 is readable.
#
#   G1 (--allowedTools Read, --permission-prompt-tool stdio):
#     called=1  hook=1  consulted=0  succeeded=0   -- byte-identical outcome, same message
#     -> **the granular deny runs FIRST. We are never asked.**
#
# Pre-registered mapping for that row: "not consulted + refused -> the granular deny runs FIRST.
# The third shape is safe." That is the outcome.
#
# So the order, with both arms combined, is:
#
#   1. toolset construction   -- a tool-NAME deny removes the tool (arm A: "No such tool available")
#   2. PreToolUse hook        -- runs, and may defer (HOOK DEFER Bash fired in both cells)
#   3. granular deny rules    -- evaluated here
#   4. can_use_tool           -- reached only if 3 permits (arm A's allow cell proves it is reached)
#
# **The third shape is therefore safe**: deferring and answering the gate's own `can_use_tool`
# preserves every layer of the user's own settings, because we are only consulted about calls that
# already survived them. The cost that decision 1's option B was believed to carry is real at
# step 3 and unreachable by an `allow`, since an `allow` cannot be offered where nothing asks.
#
# What this does NOT settle: the third shape needs `--permission-prompt-tool stdio`, which needs
# `--input-format stream-json`, which `backends/claude.lua` passes only on the duplex transport --
# and oneshot is the default. Arm B (the MCP-tool form, which needs no control channel) is the
# question of whether the same shape is available on oneshot. Its precondition -- "worth a turn
# only if the deny runs before the consultation" -- is now MET. It has not been run.
run_granular_cell() {
  local name="$1" allowed="$2" deny="$3" use_prompt_tool="$4"
  local dir="$OUT/granular-$name"
  [ -d "$dir" ] && mv "$dir" "$dir-prev-$(date +%s)"
  mkdir -p "$dir"
  export HOOK_LOG="$dir/hook.log" DRIVER_LOG="$dir/driver.log" PROBE_CWD="$dir"
  export DRIVER_TIMEOUT_SEC="${DRIVER_TIMEOUT_SEC:-180}"
  export PROBE_PROMPT='Use the Bash tool to run exactly this command: echo "ok" > probe-out.txt. Then stop.'
  : > "$HOOK_LOG"
  : > "$DRIVER_LOG"

  local settings prompt_tool_args=""
  settings=$(settings_for "$deny")
  [ "$use_prompt_tool" = "yes" ] && prompt_tool_args='"--permission-prompt-tool","stdio",'

  export CLAUDE_ARGS
  CLAUDE_ARGS=$(cat <<EOF
["-p","--input-format","stream-json","--output-format","stream-json","--verbose",
 "--model","claude-haiku-4-5-20251001","--permission-mode","default",
 "--strict-mcp-config","--setting-sources","project",
 ${prompt_tool_args}"--allowedTools","$allowed",
 "--settings",$(printf '%s' "$settings" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]
EOF
)
  echo "=== granular cell $name (allowedTools: $allowed, deny: $deny, prompt tool: $use_prompt_tool) ==="
  node "$OUT/stdio_driver.mjs"
  report "$dir" Bash
  # Printed per cell so the budget is observable while it is being spent, not reconstructed after.
  echo "cost: $(grep -o '"total_cost_usd":[0-9.]*' "$dir/driver.log" | tail -1)"
}

if [ "$ARM" = "granular" ]; then
  run_granular_cell control Bash '["Bash(echo:*)"]' no
  echo
  echo "STOP AND READ THE CONTROL BEFORE THE NEXT CELL: if the echo ran above, the rule never"
  echo "matched and the G1 cell below measures nothing about ordering."
  echo
  run_granular_cell ask Read '["Bash(echo:*)"]' yes
  exit 0
fi

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
#   consulted=0            -> **two causes, and the ASKED count cannot tell them apart.** Read
#                             ATTEMPTED in the driver log before reading anything else:
#                               ATTEMPTED Write present -> the model reached for the tool and
#                                 something refused it upstream of both the hook and the
#                                 consultation. That is the deny running first, and **the third
#                                 shape is safe**: deferring keeps the user's settings.json rules,
#                                 and only what survives them reaches us.
#                               ATTEMPTED Write absent -> the model never called the tool, so this
#                                 cell measured nothing about ordering. Re-run; do not read it as
#                                 the line above. (The probe's first run had no ATTEMPTED logging
#                                 at all and produced exactly this ambiguity.)
#   consulted, no run      -> we are asked before the deny is applied. Safe here only because
#                             something else refused it; what an allow does in general needs its own
#                             run. On arm A, also check the envelope first.
#   consulted, tool ran    -> our allow overrode the user's own deny. The third shape is B with
#                             extra steps, and decision 1 is B.
#
# --- WHAT THE RUN ACTUALLY MEASURED (claude 2.1.236, arm A, 2026-09-18) -----------------------
#
# Left above verbatim as the pre-registration. The result, recorded beneath it rather than written
# over it, so the prediction and the outcome stay separately readable:
#
#   allow cell: `--permission-prompt-tool stdio` is real and accepted. `control_request`
#     {subtype:"can_use_tool"} arrived for Write, envelope 0 (the first candidate) was acted on,
#     the Write ran. The argv and the envelope shape are re-established.
#
#   deny cell: with `permissions.deny: ["Write"]`, Write never reached the hook or the
#     consultation. The model's own tool_result reads "No such tool available: Write. Write is
#     disabled for this session, in subagents as well as here." The model then fell back to Bash,
#     which *was* consulted and allowed.
#
# **Tool-name-level deny is applied when the toolset is built, upstream of the hook and of any
# consultation.** So an `allow` written into the `.res` cannot override it -- the question is never
# put to us. The invariant this probe set out to test ("an `allow` skips the CLI's own gate, and
# with it the user's settings.json deny rules") is therefore wrong *for tool-level deny*.
#
# Two limits on that sentence, neither of them measured away:
#
#   1. The deny reached the CLI through `--settings`, with `--setting-sources project`. A `user`
#      scope deny was NOT loaded in this run. The conclusion is about where in the pipeline a deny
#      rule is applied, and sources are merged before that point -- but that merge is inferred
#      here, not observed. Closing it means writing to the real ~/.claude/settings.json, which this
#      probe refuses to do.
#   2. **Granular rules (`Bash(rm -rf:*)`) are not covered at all.** They cannot be resolved at
#      toolset-construction time, because they depend on the arguments of a specific call, so
#      nothing above predicts their ordering. `permissions.default_deny_rules` and
#      destructive_commands.lua live exactly there. B's risk is narrowed to granular rules and
#      unmeasured within them.
# Re-running the deny cell alone, once the allow cell has already been consulted in an earlier run.
# The allow cell's precondition is carried by its surviving log rather than re-bought for a turn.
if [ "$ARM" = "stdio-deny" ]; then
  if [ ! -f "$OUT/stdio-allow/driver.log" ] || ! grep -q 'ASKED' "$OUT/stdio-allow/driver.log"; then
    echo "REFUSED: no earlier arm A allow cell was consulted, so a deny cell would measure nothing."
    echo "         Run the full arm first: VIBING_PERF=1 $0"
    exit 1
  fi
  run_stdio_cell deny '["Write"]'
  exit 0
fi

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
