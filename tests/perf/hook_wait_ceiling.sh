#!/bin/bash
# How long will each CLI let a PreToolUse hook block, and what does it do when it gives up? (#778)
#
# Run with:
#   VIBING_PERF=1 tests/perf/hook_wait_ceiling.sh claude [seconds]
#   VIBING_PERF=1 tests/perf/hook_wait_ceiling.sh copilot [seconds]
#   VIBING_PERF=1 tests/perf/hook_wait_ceiling.sh grok [seconds]
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

BACKEND="${1:?usage: hook_wait_ceiling.sh <claude|copilot|grok> [seconds]}"
BUDGET="${2:-1700}"

OUT="${VIBING_PERF_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
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
  # `bypassPermissions` on purpose: that mode bypasses the permission decision but not the hook,
  # so what is timed is the hook's own ceiling and nothing else.
  local settings
  settings=$(printf '{"hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"%s","timeout":%d}]}]}}' \
    "$HOOK_CMD" "$((BUDGET + 100))")
  claude -p --output-format stream-json --verbose \
    --strict-mcp-config --setting-sources project \
    --model claude-haiku-4-5-20251001 \
    --permission-mode bypassPermissions \
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
    "$HOOK_CMD" "$((BUDGET + 100))" > "$plugin/plugin.json"
  copilot -p "$PROMPT" --allow-all-tools --plugin-dir "$plugin" \
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
    "$HOOK_CMD" "$((BUDGET + 100))" > "$repo/.grok/hooks/vibing-probe.json"
  # Proof the hook was registered at all: grok ignores an undiscovered hook in silence, which would
  # otherwise read as a ceiling of zero.
  grok inspect > "$OUT/grok-inspect.log" 2>&1 || true
  (cd "$repo" && grok -p "$PROMPT") > "$OUT/grok-stream.log" 2>&1
}

stamp_outer "CLI START backend=$BACKEND budget=${BUDGET}s out=$OUT"
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
echo "=== $BACKEND, budget ${BUDGET}s ==="
grep -E "CLI START|HOOK START|CUT BY|REACHED ITS OWN BUDGET|CLI EXIT|VERDICT" "$LOG"
echo
echo "Full log: $LOG"
