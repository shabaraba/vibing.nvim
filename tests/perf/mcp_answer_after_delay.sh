#!/bin/bash
# Is a *delayed* MCP tool answer still consumed, at the length we actually wait? (#788)
#
# Run with:
#   VIBING_PERF=1 tests/perf/mcp_answer_after_delay.sh [delay_sec]
#
# **This spends real tokens.** Same category as `hook_wait_ceiling.sh` and
# `mcp_tool_wait_ceiling.sh`, and excluded from `npm test` for the same reason. The token cost is
# nearly independent of the delay -- the model is not running while it waits -- so what a longer
# delay buys is wall clock, not money.
#
# ## Why this is not `mcp_tool_wait_ceiling.sh`
#
# That script measures a **different phenomenon**: how long the CLI tolerates a server that
# **never** answers, which it reported as "sent no response or progress for 1800s; aborting". That
# number is a ceiling on *silence*. Answering `nvim_ask_user_question` in place needs the opposite
# fact -- that a server which **does** answer, late, has its answer delivered to the model and the
# turn carries on. Reusing 1800 for that is borrowing one phenomenon's measurement for another,
# which is the same mistake as reusing the hook's `measured_wait_floor_sec` for the MCP route.
#
# ## Why the delay is the production value and not a convenient short one
#
# This produces a **floor**: "a delayed answer was consumed at least this late". A 120s cell would
# prove the mechanism exists and say nothing about 900, and the implementation uses 900. So the arm
# runs at `question_wait_sec + MCP_MARGIN_SEC` -- the whole budget vibing.nvim can hold a question
# open for -- and what survives the cell is the budget itself.
#
# ## The reading is registered before the run
#
# Five signals, counted per cell and never collapsed into one verdict
# (`handbook/architecture/approval-without-kill.md` -> "A cell is not an observation of a tool"):
#
#   1. did the model call the tool          (stream: tool_use named delayed_answer)
#   2. did the stub receive the call        (stub log: CALL)
#   3. did the stub answer                  (stub log: ANSWERED)
#   4. did the CLI deliver the result       (stream: tool_result, is_error)
#   5. did the answer reach the model       (final text contains the stub's unique marker)
#
# Signal 5 is the one that cannot be faked by the plumbing: the marker is generated per cell and
# exists nowhere in the prompt, so the model can only emit it by having been handed the result.
#
# The control cell answers immediately. It is not decoration -- without it, a failed arm has two
# possible authors ("the CLI gave up" and "this harness never measured anything"), which is exactly
# the unreadable single observation that made the 950s copilot cell worthless.
set -u

if [ "${VIBING_PERF:-}" != "1" ]; then
  echo "tests/perf/mcp_answer_after_delay.sh spends real tokens; set VIBING_PERF=1 to run it." >&2
  exit 0
fi

# Default is the production budget: permissions.approval_wait_sec (900) + MCP_MARGIN_SEC (60).
# Keep this in step with `wait_budget.lua`; a cell run at less than the configured budget measures
# something the implementation does not rely on.
DELAY="${1:-960}"
OUT="${VIBING_PERF_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"

cat > "$OUT/delayed_answer_server.mjs" <<'EOF'
// Minimal stdio MCP server whose single tool answers after DELAY_SEC seconds.
//
// It logs what it received and what it sent, with timestamps, to MCP_PROBE_LOG. That log is the
// only way to tell "the CLI gave up on us" apart from "we were never called" -- the CLI's own
// stream cannot distinguish them.
import { createInterface } from 'node:readline';
import { appendFileSync } from 'node:fs';

const DELAY_MS = Number(process.env.MCP_PROBE_DELAY_SEC || '0') * 1000;
const MARKER = process.env.MCP_PROBE_MARKER || 'MCPDELAYPROBE-UNSET';
const LOG = process.env.MCP_PROBE_LOG;

const started = Date.now();
const log = (msg) => {
  const line = `${Math.round((Date.now() - started) / 1000)}s ${msg}\n`;
  if (LOG) appendFileSync(LOG, line);
};
const send = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');

log(`STUB START delay=${DELAY_MS / 1000}s marker=${MARKER}`);

createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return;
  let req;
  try { req = JSON.parse(line); } catch { return; }

  if (req.method === 'initialize') {
    log('INITIALIZE');
    send({ jsonrpc: '2.0', id: req.id, result: {
      protocolVersion: '2024-11-05',
      capabilities: { tools: {} },
      serverInfo: { name: 'delayed-answer', version: '1.0.0' },
    }});
  } else if (req.method === 'tools/list') {
    log('TOOLS_LIST');
    send({ jsonrpc: '2.0', id: req.id, result: { tools: [{
      name: 'delayed_answer',
      description: 'Returns a secret word, slowly. Call this when asked to.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    }]}});
  } else if (req.method === 'tools/call') {
    log(`CALL ${req.params && req.params.name}`);
    // No notifications/progress: our real MCP server does not implement it either, so a cell that
    // used it would measure a mechanism production does not have.
    setTimeout(() => {
      log(`ANSWERED ${MARKER}`);
      send({ jsonrpc: '2.0', id: req.id, result: {
        content: [{ type: 'text', text: `The secret word is ${MARKER}` }],
      }});
    }, DELAY_MS);
  } else if (req.id !== undefined) {
    send({ jsonrpc: '2.0', id: req.id, result: {} });
  }
});

// The CLI closing our stdin means it has given up on the server. Recorded, because it arrives
// before any abort message the stream may or may not carry.
process.stdin.on('end', () => log('STDIN CLOSED BY CLI'));
EOF

# --- one cell -----------------------------------------------------------------------------------

# $1 cell name, $2 delay seconds
run_cell() {
  local cell="$1" delay="$2"
  local dir="$OUT/$cell"
  mkdir -p "$dir"

  local marker="MCPDELAYPROBE-${cell}-$$"
  local stub_log="$dir/stub.log"
  local stream="$dir/stream.jsonl"
  : > "$stub_log"

  echo "[$(date +%H:%M:%S)] cell=$cell delay=${delay}s starting (this blocks for about $((delay + 30))s)" >&2

  local began
  began=$(date +%s)

  # No outer timeout. Whether the CLI stays is the measurement; a `timeout` here would record our
  # own patience instead of the CLI's.
  MCP_PROBE_DELAY_SEC="$delay" \
  MCP_PROBE_MARKER="$marker" \
  MCP_PROBE_LOG="$stub_log" \
  claude -p --output-format stream-json --verbose \
    --strict-mcp-config \
    --mcp-config "{\"mcpServers\":{\"probe\":{\"command\":\"node\",\"args\":[\"$OUT/delayed_answer_server.mjs\"],\"env\":{\"MCP_PROBE_DELAY_SEC\":\"$delay\",\"MCP_PROBE_MARKER\":\"$marker\",\"MCP_PROBE_LOG\":\"$stub_log\"}}}}" \
    --setting-sources project \
    --model claude-haiku-4-5-20251001 \
    --permission-mode bypassPermissions \
    "Call the delayed_answer tool from the probe MCP server exactly once. It is slow; wait for it. When it returns, reply with exactly the secret word it gave you and nothing else." \
    > "$stream" 2> "$dir/stderr.log"
  local code=$?

  local ended
  ended=$(date +%s)

  report_cell "$cell" "$delay" "$marker" "$dir" "$stream" "$stub_log" "$code" "$((ended - began))"
}

# --- the reading, written before any of this was run --------------------------------------------

# `grep -c` prints 0 *and* exits 1 when it matches nothing, and prints nothing at all when the file
# is missing. Both shapes have to become the number 0 here, or the arithmetic tests below fail with
# a syntax error on an empty string -- a harness that dies while reporting a cell it already paid
# for. $1 pattern, $2 file.
count() {
  local n
  n=$(grep -c -- "$1" "$2" 2>/dev/null) || true
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}

# $1 cell $2 delay $3 marker $4 dir $5 stream $6 stub_log $7 exit code $8 elapsed
report_cell() {
  local cell="$1" delay="$2" marker="$3" dir="$4" stream="$5" stub_log="$6" code="$7" elapsed="$8"

  local called stub_call stub_answered delivered is_error marker_seen stdin_closed
  called=$(count '"name":"mcp__probe__delayed_answer"' "$stream")
  stub_call=$(count 'CALL ' "$stub_log")
  stub_answered=$(count 'ANSWERED ' "$stub_log")
  stdin_closed=$(count 'STDIN CLOSED BY CLI' "$stub_log")
  delivered=$(count '"type":"tool_result"' "$stream")
  is_error=$(grep -o '"is_error": *[a-z]*' "$stream" 2>/dev/null | tail -1)
  marker_seen=$(count "$marker" "$stream")

  # Whether the delivered result was an error. Absent counts as absent, not as false: "no
  # tool_result at all" and "a tool_result saying false" are different observations.
  local errored="?"
  case "$is_error" in
    *false) errored="no" ;;
    *true) errored="yes" ;;
  esac

  echo
  echo "=== cell $cell (delay=${delay}s, wall=${elapsed}s, exit=$code) ==="
  echo "  1. model called the tool      : $called"
  echo "  2. stub received tools/call   : $stub_call"
  echo "  3. stub sent its answer       : $stub_answered"
  echo "  4. CLI delivered a tool_result: $delivered (is_error=$errored)"
  echo "  5. marker present in stream   : $marker_seen occurrence(s) of $marker"
  echo "     CLI closed the stub's stdin: $stdin_closed"

  # Pre-registered mapping. Ordered so that a missing *instrument* is never read as a zero of the
  # thing being measured -- the defect that page has caught three times. Signal 1 is tested before
  # signal 3 for the same reason: "the stub never answered" is only meaningful once we know it was
  # asked.
  echo -n "  READING: "
  if [ "$called" -eq 0 ]; then
    echo "? INSTRUMENT NOT EXERCISED"
    echo "           The model never called the tool, so this cell measures the prompt, not the CLI."
    echo "           Nothing may be concluded about a delayed answer. Re-run."
  elif [ "$stub_call" -eq 0 ]; then
    echo "? INSTRUMENT FAILURE"
    echo "           The model called it but the stub never saw it (mcp-config or spawn problem)."
    echo "           Not evidence about patience in either direction."
  elif [ "$stub_answered" -eq 0 ]; then
    echo "FAIL -- the stub never reached its answer; the CLI gave up before ${delay}s."
  elif [ "$delivered" -eq 0 ]; then
    echo "FAIL -- the stub answered but the CLI delivered no tool_result: it had stopped listening."
  elif [ "$errored" = "yes" ]; then
    echo "FAIL -- the result came back as an error, so a ${delay}s answer is not usable as one."
  elif [ "$errored" = "no" ] && [ "$marker_seen" -ge 2 ]; then
    echo "PASS (strong) -- a delayed MCP answer is consumed at ${delay}s."
    echo "           The result was delivered without error, and the marker appears twice: once as"
    echo "           the CLI handing it over and once in the model's own text, which it could only"
    echo "           have learned from the result. The marker is generated per cell and is nowhere"
    echo "           in the prompt."
    echo "           **This is a FLOOR**: the answer survived ${delay}s. It is not the wall."
  elif [ "$errored" = "no" ] && [ "$marker_seen" -ge 1 ]; then
    echo "PASS -- a delayed MCP answer is consumed at ${delay}s: delivered, no error, and carrying"
    echo "           our marker. The model did not echo it back, so only the delivery is evidenced."
    echo "           **This is a FLOOR**: the answer survived ${delay}s. It is not the wall."
  else
    echo "AMBIGUOUS -- the signals disagree. Read $stream and $stub_log by hand before concluding"
    echo "           anything, and do not summarise this cell as either outcome."
  fi
  echo "  logs: $dir"
}

# --- self-test: does the mapping above actually distinguish the outcomes? ------------------------
#
# Four crafted cells, no tokens. Each mutant of `report_cell` should break exactly one of them; a
# case that passes for every mutant is a case that is not checking anything.
if [ "${1:-}" = "self-test" ]; then
  T=$(mktemp -d)
  fail=0
  check() { # $1 name, $2 expected substring, $3 stream, $4 stub log
    local got
    got=$(report_cell "$1" 960 "MARKER-X" "$T" "$3" "$4" 0 960)
    if printf '%s' "$got" | grep -q -- "$2"; then
      echo "ok   $1 -> $2"
    else
      echo "FAIL $1: expected '$2'"; printf '%s\n' "$got"; fail=1
    fi
  }

  printf '' > "$T/empty"
  printf 'x\n' > "$T/nostub"

  printf '{"name":"mcp__probe__delayed_answer"}\n{"type":"tool_result","is_error":false}\nMARKER-X\nMARKER-X\n' > "$T/s_pass"
  printf '0s CALL delayed_answer\n0s ANSWERED MARKER-X\n' > "$T/l_pass"
  check "pass" "PASS (strong)" "$T/s_pass" "$T/l_pass"

  check "never-called" "INSTRUMENT NOT EXERCISED" "$T/nostub" "$T/empty"

  printf '{"name":"mcp__probe__delayed_answer"}\n' > "$T/s_called"
  check "stub-never-saw-it" "INSTRUMENT FAILURE" "$T/s_called" "$T/empty"

  printf '0s CALL delayed_answer\n' > "$T/l_gaveup"
  check "cli-gave-up" "FAIL -- the stub never reached its answer" "$T/s_called" "$T/l_gaveup"

  printf '{"name":"mcp__probe__delayed_answer"}\n{"type":"tool_result","is_error":true}\nMARKER-X\n' > "$T/s_err"
  check "errored" "FAIL -- the result came back as an error" "$T/s_err" "$T/l_pass"

  # The marker appearing **once** is the CLI handing the result over; appearing **twice** is the
  # model having read it. Both are a pass and they are not the same evidence, so the threshold that
  # separates them needs a case of its own -- without this one, lowering it to `-ge 0` changes
  # nothing that any test can see, and the strong claim becomes printable for a cell that never
  # earned it.
  printf '{"name":"mcp__probe__delayed_answer"}\n{"type":"tool_result","is_error":false}\nMARKER-X\n' > "$T/s_once"
  check "delivered-not-echoed" "PASS -- a delayed MCP answer is consumed" "$T/s_once" "$T/l_pass"

  rm -rf "$T"
  exit $fail
fi

echo "=== delayed MCP answer, arm delay=${DELAY}s, out=$OUT ==="
echo "Control first: it is what makes a failing arm readable."

run_cell control 0
run_cell "arm-${DELAY}s" "$DELAY"

echo
echo "Both cells above are per-cell readings. The arm means nothing unless the control says PASS."
echo "Full logs: $OUT"
