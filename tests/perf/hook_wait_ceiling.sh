#!/bin/bash
# How long will each CLI let a PreToolUse hook block, and what does it do when it gives up? (#778)
#
# Run with:
#   # ceiling: how long will it wait when we ask it to?
#   VIBING_PERF=1 tests/perf/hook_wait_ceiling.sh claude 1700
#   # expiry: what does it do when it gives up?  (block 120s against a 30s configured timeout)
#   VIBING_PERF=1 tests/perf/hook_wait_ceiling.sh copilot 120 30
#   # the same expiry, with no gate left to fall back on
#   VIBING_PERF=1 tests/perf/hook_wait_ceiling.sh claude 120 30 bypassPermissions
#   # expiry with the CLI's own gate pre-set to allow, so the hook is the only decider
#   VIBING_PERF=1 tests/perf/hook_wait_ceiling.sh claude 120 30 default yes
#
# **This spends real tokens, and it is slow by construction** -- the measurement *is* the waiting.
# It is not part of `npm test` and cannot be: codex and grok need credentials this machine may not
# have, so there is no configuration in which all four backends answer. It exists because
# `permissions.approval_wait_sec` is a measured number, and the number is pinned to a CLI version:
# re-run this after a CLI upgrade and update the table in
# `handbook/architecture/cli-integration.md`.
#
# What is being decided. Answering an approval without killing the process means the hook blocks
# until a human answers, so "how long may it block" is the ceiling the feature lives under. The
# second half matters more than the first: claude **fails closed** past its timeout (the tool is
# refused) while copilot's own source comments claim it **fails open** (the tool runs ungated). A
# backend that fails open must not be allowed to wait at all, because waiting would turn a slow
# human into a bypassed permission gate.
#
# The hook logs a heartbeat every 10s and traps every signal a CLI might cut it with, so the log
# distinguishes "still allowed to wait" from "stopped, and stopped this way". The tool the model is
# asked to run creates a file, so the file's existence afterwards is the fail-open verdict --
# independent of anything the CLI reports about itself.
set -u

if [ "${VIBING_PERF:-}" != "1" ]; then
  echo "tests/perf/hook_wait_ceiling.sh spends real tokens; set VIBING_PERF=1 to run it." >&2
  exit 0
fi

BACKEND="${1:?usage: hook_wait_ceiling.sh <claude|copilot|grok> [block_sec] [configured_timeout_sec]}"
BUDGET="${2:-1700}"
# Two modes, and the second one is the only way to see the interesting half.
#
#   ceiling mode (default): configured timeout ABOVE the block, so the hook is never cut and the
#     run answers "how long is a CLI willing to wait when we ask it to".
#   expiry mode: configured timeout BELOW the block, so the timeout is definitely reached and the
#     run answers "what does the CLI do when it gives up" -- fail closed (the tool is refused) or
#     fail open (the tool runs ungated). Cheap: a 30s timeout against a 120s block settles it in
#     two minutes, where waiting out a real ceiling takes half an hour and never reaches expiry.
CONFIGURED="${3:-$((BUDGET + 100))}"
# The permission mode the run happens under, because **it changes what expiry means**. Under
# `bypassPermissions` there is no gate left to refuse a tool whose hook timed out, so the CLI
# proceeds -- measured, and not evidence about the mode real chats use. `default` is the mode a
# vibing.nvim chat runs in, so it is the default here too; pass `bypassPermissions` explicitly to
# measure that half.
PERMISSION_MODE="${4:-default}"
# Whether the CLI's **own** gate is pre-set to allow the tool, which decides whether the expiry
# reading is about the hook at all.
#
# In headless `default` mode the gate has nobody to prompt, so it refuses a tool it has no rule
# for. "The tool did not run" then has two possible authors -- the hook failing closed, or the gate
# denying something the hook never got a verdict on -- and the run cannot tell them apart. Pre-
# allowing the tool removes the gate from the experiment: PreToolUse runs *before* it, so with the
# gate guaranteed to say yes, whatever decides the outcome is the hook.
#
# That the hook still fires when the tool is pre-allowed is not assumed; `HOOK START` in the log is
# the proof, and a run without it measured nothing.
GATE_PREALLOWED="${5:-no}"

# Absolute, always. The hook runs with the CLI's working directory, not this script's, so a
# relative path here makes the hook fail on its very first write -- and a hook that errors is a
# different measurement from a hook that blocks, reported in the same place.
OUT="${VIBING_PERF_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
HOOK="$OUT/blocking-hook.sh"
LOG="$OUT/hook-$BACKEND.log"
: > "$LOG"

# The hook, written out rather than kept as a repo file: every backend needs the same one, and a
# second file on disk is one more thing to keep in step with the three launch paths below.
cat > "$HOOK" <<'HOOK_EOF'
#!/bin/bash
LOG="${HOOK_PROBE_LOG:?}"
BUDGET="${HOOK_PROBE_SLEEP:-1700}"
ELAPSED=0
stamp() { echo "$(date +%s) $(date +%H:%M:%S) $*" >> "$LOG"; }
trap 'stamp "CUT BY SIGTERM after ${ELAPSED}s"; exit 0' TERM
trap 'stamp "CUT BY SIGINT after ${ELAPSED}s"; exit 0' INT
trap 'stamp "CUT BY SIGHUP after ${ELAPSED}s"; exit 0' HUP
cat > /dev/null
stamp "HOOK START pid=$$ budget=${BUDGET}s"
while [ "$ELAPSED" -lt "$BUDGET" ]; do
  sleep 10
  ELAPSED=$((ELAPSED + 10))
  stamp "alive ${ELAPSED}s"
done
stamp "HOOK REACHED ITS OWN BUDGET after ${ELAPSED}s without being cut (exiting 0 = defer)"
HOOK_EOF
chmod +x "$HOOK"

export HOOK_PROBE_LOG="$LOG"
export HOOK_PROBE_SLEEP="$BUDGET"
HOOK_CMD="env HOOK_PROBE_LOG=$LOG HOOK_PROBE_SLEEP=$BUDGET bash $HOOK"

# One file, created by one tool call. Its existence after the run is the fail-open verdict.
MARKER="$OUT/hook-wait-marker.txt"
rm -f "$MARKER"
PROMPT="Use the Write tool to create the file $MARKER containing exactly: ok. Then stop."

stamp_outer() { echo "$(date +%s) $(date +%H:%M:%S) $*" >> "$LOG"; }

run_claude() {
  local settings preallow=()
  [ "$GATE_PREALLOWED" = "yes" ] && preallow=(--allowedTools Write)
  settings=$(printf '{"hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"%s","timeout":%d}]}]}}' \
    "$HOOK_CMD" "$CONFIGURED")
  claude -p --output-format stream-json --verbose \
    --strict-mcp-config --setting-sources project \
    --model claude-haiku-4-5-20251001 \
    --permission-mode "$PERMISSION_MODE" \
    "${preallow[@]}" \
    --settings "$settings" \
    "$PROMPT" > "$OUT/claude-stream.jsonl" 2> "$OUT/claude-stderr.log"
}

run_copilot() {
  # Copilot's own schema, mirrored from `copilot_settings_generator.lua`: lowercase `preToolUse`,
  # the command under `bash`, `timeoutSec` rather than `timeout`, and no matcher (a `*` is compiled
  # as a regex and rejected, so the hook would be skipped entirely).
  local plugin="$OUT/copilot-plugin"
  rm -rf "$plugin"; mkdir -p "$plugin"
  printf '{"name":"vibing-hook-wait-probe","description":"measures copilot preToolUse ceiling","version":"1.0.0","hooks":{"preToolUse":[{"type":"command","bash":"%s","timeoutSec":%d}]}}' \
    "$HOOK_CMD" "$CONFIGURED" > "$plugin/plugin.json"
  # `--allow-all-tools` is copilot's nearest equivalent of bypassPermissions, so it is applied only
  # when that mode was asked for; otherwise copilot's own gate stays in place, which is what a
  # vibing.nvim chat has.
  local allow=()
  [ "$PERMISSION_MODE" = "bypassPermissions" ] && allow=(--allow-all-tools)
  [ "$GATE_PREALLOWED" = "yes" ] && allow=(--allow-tool write)
  copilot -p "$PROMPT" "${allow[@]}" --plugin-dir "$plugin" \
    > "$OUT/copilot-stream.log" 2>&1
}

run_grok() {
  # Grok reads claude's hook schema but discovers `.grok/hooks/` only inside a **trusted git
  # repository**, so both are built here. GROK_HOME is redirected: writing into the real
  # `~/.grok/trusted_folders.toml` would grant trust that outlives the measurement.
  local repo="$OUT/grokrepo"
  rm -rf "$repo"; mkdir -p "$repo/.grok/hooks"
  git -C "$repo" init -q
  local real; real="$(cd "$repo" && pwd -P)"
  export GROK_HOME="$OUT/grokhome"
  rm -rf "$GROK_HOME"; mkdir -p "$GROK_HOME"
  printf '[folders."%s"]\ntrusted = true\ndecided_at = %d\n' "$real" "$(date +%s)" \
    > "$GROK_HOME/trusted_folders.toml"
  printf '{"hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"%s","timeout":%d}]}]}}' \
    "$HOOK_CMD" "$CONFIGURED" > "$repo/.grok/hooks/vibing-probe.json"
  # Proof the hook was registered at all: grok ignores an undiscovered hook in silence, which would
  # otherwise read as a ceiling of zero.
  grok inspect > "$OUT/grok-inspect.log" 2>&1 || true
  (cd "$repo" && grok -p "$PROMPT") > "$OUT/grok-stream.log" 2>&1
}

stamp_outer "CLI START backend=$BACKEND block=${BUDGET}s configured_timeout=${CONFIGURED}s mode=$PERMISSION_MODE gate_preallowed=$GATE_PREALLOWED out=$OUT"
case "$BACKEND" in
  claude) run_claude ;;
  copilot) run_copilot ;;
  grok) run_grok ;;
  *) echo "unsupported backend: $BACKEND (codex has no measured path here yet)" >&2; exit 1 ;;
esac
stamp_outer "CLI EXIT code=$?"

if [ -f "$MARKER" ]; then
  stamp_outer "VERDICT: FAIL OPEN - the tool ran even though the hook never returned a decision"
else
  stamp_outer "VERDICT: the tool did not run"
fi

echo
echo "=== $BACKEND, block ${BUDGET}s, configured timeout ${CONFIGURED}s, mode ${PERMISSION_MODE}, gate preallowed ${GATE_PREALLOWED} ==="
grep -E "CLI START|HOOK START|CUT BY|REACHED ITS OWN BUDGET|CLI EXIT|VERDICT" "$LOG"
echo
echo "Full log: $LOG"
