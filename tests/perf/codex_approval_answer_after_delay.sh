#!/bin/bash
# Is a *delayed* answer to a Codex app-server approval request still consumed? (#861)
#
# Run with:
#   VIBING_PERF=1 tests/perf/codex_approval_answer_after_delay.sh [delay_sec]
#
# **This spends real tokens.** Same category as `mcp_answer_after_delay.sh`, and outside `npm test`
# for the same reason. The cost is nearly independent of the delay -- the model is not running while
# it waits -- so a longer delay buys wall clock, not money.
#
# ## What this measures, and what it does not
#
# Codex's native approval is a **third channel**, next to the PreToolUse hook and the MCP tool call.
# `hook.measured_wait_floor_sec` times a hook blocking; `mcp.measured_answer_wait_sec` times a late
# MCP answer being consumed. Neither says anything about a server->client JSON-RPC request on a
# resident `codex app-server`, which is what this one times. Borrowing either number for it is the
# same error those two comments already name.
#
# ## Why the delay is the production value
#
# This produces a **floor**: "a decision this late was still acted on". A 60s cell would prove the
# mechanism exists and say nothing about 900, and the implementation waits
# `permissions.approval_wait_sec`. So the arm runs at the whole budget vibing.nvim can hold a prompt
# open for, and what survives the cell is the budget itself.
#
# ## The reading is registered before the run
#
# Five signals, counted per cell and never collapsed into one verdict:
#
#   1. did codex ask                      (log: APPROVAL REQUEST)
#   2. did the probe answer               (log: REPLYING)
#   3. did codex take the answer          (log: serverRequest/resolved for that id)
#   4. did the approved command RUN       (the cell's marker file exists on disk)
#   5. did the turn finish normally       (log: turn/completed status=completed)
#
# Signal 4 is the one the plumbing cannot fake: the marker path is generated per cell, exists
# nowhere else, and only the approved command creates it. Signal 1 failing means the cell measured
# the prompt rather than codex, which is an instrument failure and not a reading.
#
# The control cell answers immediately. Without it a failing arm has two possible authors -- "codex
# gave up" and "this harness never measured anything" -- which is the unreadable single observation.
set -u

if [ "${VIBING_PERF:-}" != "1" ]; then
  echo "tests/perf/codex_approval_answer_after_delay.sh spends real tokens; set VIBING_PERF=1." >&2
  exit 0
fi

# Default is the production budget: permissions.approval_wait_sec (900) + a margin for carrying the
# decision home. Keep in step with `wait_budget.lua`; a cell shorter than the configured budget
# measures something the implementation does not rely on.
DELAY="${1:-960}"
OUT="${VIBING_PERF_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"

cat > "$OUT/driver.mjs" <<'EOF'
// Drive `codex app-server` by hand until it asks for an approval, then answer it after a delay.
//
// No vibing.nvim code is involved: the point is to characterise the CLI, so anything of ours in the
// path would be a second thing the cell could be measuring.
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { appendFileSync } from 'node:fs';

const POLICY = process.env.PROBE_POLICY || 'on-request';
const SANDBOX = process.env.PROBE_SANDBOX || 'read-only';
const MARKER = process.env.PROBE_MARKER;
const DELAY_MS = Number(process.env.PROBE_DELAY || '0') * 1000;
const DECISION = process.env.PROBE_DECISION || 'accept';
const LOG = process.env.PROBE_LOG;
const CWD = process.env.PROBE_CWD || process.cwd();
// Its own deadline, because macOS has no `timeout(1)`. Comfortably past the delay: a probe that
// gave up first would record our patience instead of codex's.
const MAX_SEC = Number(process.env.PROBE_MAX_SEC || String(Number(process.env.PROBE_DELAY || '0') + 300));
const PROMPT =
  `Create the file ${MARKER} containing the word ok, using a single shell command. ` +
  'You will need to request approval to escape the read-only sandbox; do that. Do not explain.';

const started = Date.now();
const at = () => Math.round((Date.now() - started) / 1000);
const log = (msg) => appendFileSync(LOG, `${at()}s ${msg}\n`);

const argv = ['app-server', '--listen', 'stdio://', '-c', `approval_policy="${POLICY}"`, '-c', `sandbox_mode="${SANDBOX}"`];
log(`SPAWN codex ${argv.join(' ')}`);
const child = spawn('codex', argv, { stdio: ['pipe', 'pipe', 'pipe'] });

setTimeout(() => {
  log(`PROBE DEADLINE ${MAX_SEC}s reached`);
  child.kill();
  process.exit(3);
}, MAX_SEC * 1000).unref();

let seq = 0;
const pending = new Map();
const send = (msg) => {
  log(`-> ${JSON.stringify(msg)}`);
  child.stdin.write(JSON.stringify(msg) + '\n');
};
const request = (method, params, cb) => {
  const id = `probe-${++seq}`;
  pending.set(id, cb);
  send({ id, method, params });
};

createInterface({ input: child.stdout }).on('line', (line) => {
  if (!line.trim()) return;
  log(`<- ${line}`);
  let msg;
  try { msg = JSON.parse(line); } catch { return; }

  if (msg.id !== undefined && !msg.method) {
    const cb = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) return log(`ERROR ${JSON.stringify(msg.error)}`);
    if (cb) cb(msg.result || {});
    return;
  }

  if (msg.id !== undefined && msg.method) {
    if (String(msg.method).toLowerCase().includes('approval')) {
      log(`APPROVAL REQUEST method=${msg.method} id=${JSON.stringify(msg.id)}`);
      log(`APPROVAL PARAMS ${JSON.stringify(msg.params)}`);
      setTimeout(() => {
        log(`REPLYING to ${JSON.stringify(msg.id)} with decision=${DECISION}`);
        send({ id: msg.id, result: { decision: DECISION } });
      }, DELAY_MS);
      return;
    }
    log(`OTHER SERVER REQUEST ${msg.method}; answering -32601`);
    send({ id: msg.id, error: { code: -32601, message: 'probe does not implement ' + msg.method } });
    return;
  }

  if (msg.method === 'turn/completed') {
    const turn = (msg.params || {}).turn || {};
    log(`TURN COMPLETED status=${turn.status}`);
    setTimeout(() => { child.kill(); process.exit(0); }, 500);
  }
});

createInterface({ input: child.stderr }).on('line', (line) => log(`STDERR ${line}`));
child.on('exit', (code, signal) => {
  log(`CODEX EXITED code=${code} signal=${signal}`);
  process.exit(code === null ? 1 : code);
});

request('initialize', { clientInfo: { name: 'vibing-perf-probe', title: 'approval probe', version: '0.0.1' } }, () => {
  send({ method: 'initialized' });
  request('thread/start', { cwd: CWD }, (result) => {
    const threadId = result.thread && result.thread.id;
    log(`THREAD ${threadId}`);
    request('turn/start', { threadId, input: [{ type: 'text', text: PROMPT }] }, (r) => log(`TURN ${(r.turn || {}).id}`));
  });
});
EOF

# `grep -c` prints 0 *and* exits 1 on no match, and prints nothing at all for a missing file. Both
# have to become the number 0, or the arithmetic below dies while reporting a cell already paid for.
count() {
  local n
  n=$(grep -c -- "$1" "$2" 2>/dev/null) || true
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}

# $1 cell $2 delay $3 dir $4 log $5 marker path $6 exit code $7 elapsed
report_cell() {
  local cell="$1" delay="$2" dir="$3" log="$4" marker="$5" code="$6" elapsed="$7"

  local asked replied resolved completed ran
  asked=$(count 'APPROVAL REQUEST' "$log")
  replied=$(count 'REPLYING to' "$log")
  resolved=$(count 'serverRequest/resolved' "$log")
  completed=$(count 'TURN COMPLETED status=completed' "$log")
  ran=0
  [ -f "$marker" ] && ran=1

  echo
  echo "=== cell $cell (delay=${delay}s, wall=${elapsed}s, exit=$code) ==="
  echo "  1. codex asked for approval   : $asked"
  echo "  2. probe answered it          : $replied"
  echo "  3. codex took the answer      : $resolved (serverRequest/resolved)"
  echo "  4. the approved command RAN   : $ran ($marker)"
  echo "  5. turn completed normally    : $completed"

  # Ordered so a missing instrument is never read as a zero of the thing being measured.
  echo -n "  READING: "
  if [ "$asked" -eq 0 ]; then
    echo "? INSTRUMENT NOT EXERCISED"
    echo "           codex never asked, so this cell measures the prompt and the policy, not the"
    echo "           wait. Nothing may be concluded in either direction. Re-run."
  elif [ "$replied" -eq 0 ]; then
    echo "? INSTRUMENT FAILURE -- the probe never got as far as answering."
  elif [ "$resolved" -eq 0 ]; then
    echo "FAIL -- codex never acknowledged the decision: it had stopped waiting before ${delay}s."
  elif [ "$ran" -eq 0 ]; then
    echo "FAIL -- codex took the decision but the approved command never ran, so an answer this"
    echo "           late is not usable as one."
  elif [ "$completed" -eq 0 ]; then
    echo "PARTIAL -- the command ran but the turn did not complete normally. Read $log by hand."
  else
    echo "PASS -- a decision delivered ${delay}s late is still acted on: codex acknowledged it, the"
    echo "           approved command ran, and the turn finished normally."
    echo "           **This is a FLOOR**: the decision survived ${delay}s. It is not the wall."
  fi
  echo "  log: $log"
}

# $1 cell name, $2 delay seconds
run_cell() {
  local cell="$1" delay="$2"
  local dir="$OUT/$cell"
  mkdir -p "$dir"
  local log="$dir/probe.log"
  local marker="$dir/approved-$$.txt"
  : > "$log"

  echo "[$(date +%H:%M:%S)] cell=$cell delay=${delay}s starting (blocks for about $((delay + 30))s)" >&2
  local began
  began=$(date +%s)

  PROBE_LOG="$log" PROBE_MARKER="$marker" PROBE_DELAY="$delay" PROBE_DECISION=accept \
    PROBE_CWD="$dir" node "$OUT/driver.mjs" >/dev/null 2>"$dir/stderr.log"
  local code=$?

  report_cell "$cell" "$delay" "$dir" "$log" "$marker" "$code" "$(($(date +%s) - began))"
}

# --- self-test: does the mapping above actually distinguish the outcomes? ------------------------
#
# Crafted cells, no tokens. Each mutant of `report_cell` should break exactly one of them.
if [ "${1:-}" = "self-test" ]; then
  T=$(mktemp -d)
  fail=0
  check() { # $1 name, $2 expected substring, $3 log, $4 marker
    local got
    got=$(report_cell "$1" 960 "$T" "$3" "$4" 0 960)
    if printf '%s' "$got" | grep -q -- "$2"; then
      echo "ok   $1 -> $2"
    else
      echo "FAIL $1: expected '$2'"; printf '%s\n' "$got"; fail=1
    fi
  }

  : > "$T/empty"
  printf 'ok' > "$T/marker_present"

  printf 'APPROVAL REQUEST x\nREPLYING to 0\nserverRequest/resolved\nTURN COMPLETED status=completed\n' > "$T/l_pass"
  check "pass" "PASS -- a decision delivered" "$T/l_pass" "$T/marker_present"

  check "never-asked" "INSTRUMENT NOT EXERCISED" "$T/empty" "$T/marker_present"

  printf 'APPROVAL REQUEST x\n' > "$T/l_noreply"
  check "never-answered" "INSTRUMENT FAILURE" "$T/l_noreply" "$T/missing"

  printf 'APPROVAL REQUEST x\nREPLYING to 0\n' > "$T/l_gaveup"
  check "codex-gave-up" "FAIL -- codex never acknowledged" "$T/l_gaveup" "$T/missing"

  printf 'APPROVAL REQUEST x\nREPLYING to 0\nserverRequest/resolved\n' > "$T/l_noran"
  check "not-run" "FAIL -- codex took the decision but the approved command never ran" "$T/l_noran" "$T/missing"

  # The command running and the turn finishing are different observations: without this case,
  # dropping signal 5 from the mapping changes nothing any test can see.
  check "ran-but-unfinished" "PARTIAL" "$T/l_noran" "$T/marker_present"

  rm -rf "$T"
  exit $fail
fi

echo "=== codex native approval, arm delay=${DELAY}s, out=$OUT ==="
echo "Control first: it is what makes a failing arm readable."

run_cell control 0
run_cell "arm-${DELAY}s" "$DELAY"

echo
echo "Both cells above are per-cell readings. The arm means nothing unless the control says PASS."
echo "Full logs: $OUT"
