#!/bin/bash
# Does a CLI run two PreToolUse hooks at the same time? (#778)
#
# Run with:
#   VIBING_PERF=1 tests/perf/hook_concurrency.sh claude 20
#
# **This spends real tokens.** It is not part of `npm test`.
#
# What is being decided. Answering an approval without killing the CLI means the hook blocks until a
# human answers. If a CLI issues several tool calls at once and runs a hook for each, a single chat
# can have **more than one hook blocked simultaneously** — and a chat has one approval prompt slot.
# Whether that happens is a fact about the CLI, and this issue has already mistaken "we stopped
# watching" for "the CLI stopped" three times, so it is measured rather than assumed.
#
# How. Every hook invocation logs its pid, the tool it was asked about, and a timestamp at entry and
# at exit, then sleeps for a fixed block. Overlapping [start, end] intervals mean concurrent hooks.
# The block has to be long enough that overlap is unambiguous and short enough that a serial run
# still finishes: with three tools and a 20s block, serial is ~60s and parallel is ~20s, which the
# wall clock alone distinguishes.
#
# The tools are pre-allowed (`--allowedTools Read`). Without that, the CLI's own gate refuses in
# headless `default` mode and the run measures the gate instead of the hook — the same confound
# recorded in handbook/architecture/approval-without-kill.md.
set -u

if [ "${VIBING_PERF:-}" != "1" ]; then
  echo "tests/perf/hook_concurrency.sh spends real tokens; set VIBING_PERF=1 to run it." >&2
  exit 0
fi

BACKEND="${1:?usage: hook_concurrency.sh <claude|copilot> [block_sec]}"
BLOCK="${2:-20}"

OUT="${VIBING_PERF_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
HOOK="$OUT/concurrency-hook.sh"
LOG="$OUT/hook-concurrency-$BACKEND.log"
: > "$LOG"

# Three files for the model to read. Real files, because a Read of a missing path may not reach
# PreToolUse at all on every backend.
for n in 1 2 3; do
  printf 'probe file %s\n' "$n" > "$OUT/probe-$n.txt"
done

cat > "$HOOK" <<'HOOK_EOF'
#!/bin/bash
LOG="${HOOK_PROBE_LOG:?}"
BLOCK="${HOOK_PROBE_BLOCK:-20}"
INPUT=$(cat)
# The payload's own spelling, not a canonical name: this is the raw hook input, and the point is
# only to tell the three invocations apart.
TARGET=$(printf '%s' "$INPUT" | grep -o '"file_path":"[^"]*"' | head -1 | cut -d'"' -f4)
TARGET="${TARGET##*/}"
# Nanoseconds would be better but `date +%s%N` is GNU-only; python3 is present on macOS and gives
# the sub-second resolution this needs, since a serial run's gap can be small.
now() { python3 -c 'import time; print("%.3f" % time.time())'; }
echo "$(now) START pid=$$ target=${TARGET:-unknown}" >> "$LOG"
sleep "$BLOCK"
echo "$(now) END   pid=$$ target=${TARGET:-unknown}" >> "$LOG"
exit 0
HOOK_EOF
chmod +x "$HOOK"

HOOK_CMD="env HOOK_PROBE_LOG=$LOG HOOK_PROBE_BLOCK=$BLOCK bash $HOOK"

PROMPT="Read these three files, then stop: $OUT/probe-1.txt $OUT/probe-2.txt $OUT/probe-3.txt"

stamp() { python3 -c 'import time; print("%.3f" % time.time())' | tr -d '\n' >> "$LOG"; echo " $*" >> "$LOG"; }

run_claude() {
  # A configured timeout far above the block, so nothing here is a timeout measurement.
  local settings
  settings=$(printf '{"hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"%s","timeout":600}]}]}}' \
    "$HOOK_CMD")
  claude -p --output-format stream-json --verbose \
    --strict-mcp-config --setting-sources project \
    --model claude-haiku-4-5-20251001 \
    --permission-mode default \
    --allowedTools Read \
    --settings "$settings" \
    "$PROMPT" > "$OUT/claude-stream.jsonl" 2> "$OUT/claude-stderr.log"
}

run_copilot() {
  local plugin="$OUT/copilot-plugin"
  rm -rf "$plugin"; mkdir -p "$plugin"
  printf '{"name":"vibing-hook-concurrency-probe","description":"measures concurrent preToolUse hooks","version":"1.0.0","hooks":{"preToolUse":[{"type":"command","bash":"%s","timeoutSec":600}]}}' \
    "$HOOK_CMD" > "$plugin/plugin.json"
  copilot -p "$PROMPT" --allow-tool read --plugin-dir "$plugin" > "$OUT/copilot-stream.log" 2>&1
}

stamp "CLI START backend=$BACKEND block=${BLOCK}s out=$OUT"
case "$BACKEND" in
  claude) run_claude ;;
  copilot) run_copilot ;;
  *) echo "unsupported backend: $BACKEND" >&2; exit 1 ;;
esac
stamp "CLI EXIT code=$?"

echo
echo "=== $BACKEND, ${BLOCK}s block per hook ==="
cat "$LOG"
echo
# The verdict is computed rather than eyeballed: reading interleaved timestamps by eye is how a
# marginal overlap gets called either way depending on what the reader expected.
python3 - "$LOG" "$BLOCK" <<'PY'
import sys

log, block = sys.argv[1], float(sys.argv[2])
spans = {}
for line in open(log):
    parts = line.split()
    if len(parts) < 3 or parts[1] not in ("START", "END"):
        continue
    ts, kind, pid = float(parts[0]), parts[1], parts[2].removeprefix("pid=")
    spans.setdefault(pid, {})[kind] = ts

done = [(v["START"], v["END"], pid) for pid, v in spans.items() if "START" in v and "END" in v]
done.sort()
print(f"hook invocations that completed: {len(done)}")
if len(done) < 2:
    print("VERDICT: inconclusive - fewer than two hooks ran")
    raise SystemExit

overlaps = [
    (a, b) for i, a in enumerate(done) for b in done[i + 1:]
    if a[0] < b[1] and b[0] < a[1]
]
first, last = done[0][0], max(e for _, e, _ in done)
print(f"wall clock across all hooks: {last - first:.1f}s (serial would be ~{block * len(done):.0f}s)")
for s, e, pid in done:
    print(f"  pid={pid} {s - first:7.3f} -> {e - first:7.3f}")
print("VERDICT: CONCURRENT" if overlaps else "VERDICT: SERIAL")
PY
echo
echo "Full log: $LOG"
