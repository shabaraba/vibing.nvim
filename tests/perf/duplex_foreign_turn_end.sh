#!/bin/bash
# Which `result` on a resident CLI belongs to the prompt we wrote? (#842)
#
# Run with:
#   VIBING_PERF=1 tests/perf/duplex_foreign_turn_end.sh
#
# **This spends real tokens.** Same category as the other scripts here, and excluded from
# `npm test` for the same reason. One background subagent, four short turns; a few cents.
#
# ## The phenomenon
#
# The CLI runs turns nobody asked for. A background subagent finishing delivers a
# `system/task_notification`, and the CLI answers it **by itself** on the same resident process --
# a full `system/init` ... `result` pair. `duplex_turn.lua` ends the turn on `result`, so one of
# those landing between a prompt and its answer ends the user's turn with nothing in it, and the
# real answer goes to `_idle_context` and is dropped. Every later turn is then off by one.
#
# ## The reading is registered before the run
#
# Four cells, each one a `result` whose `user_message_uuid` is either the id we wrote or absent.
# The field is what the fix reads, so each cell is a direct observation of the fix's input:
#
#   1. an ordinary prompt          -> echoes our uuid          (the correlation exists at all)
#   2. a slash command (`/compact`) -> echoes our uuid          (a turn the CLI spends 30s inside)
#   3. an interrupted turn          -> echoes our uuid          (`error_during_execution`)
#   4. a `task_notification` turn   -> **no field at all**      (the one we must not consume)
#
# Cell 4 alone would not license the fix: "no uuid" is also what a CLI that does not echo produces.
# Cells 1-3 are the control that rules that out, which is why they are not decoration. Cells 2 and
# 3 are separately load-bearing -- if either lost the uuid, the fix would hang `/compact` or
# `<C-c>` rather than repair anything, and the design would have to be a different one.
#
# `command_lifecycle` is recorded alongside: it is emitted **only** when the input envelope carried
# a `uuid`, which is the proof-of-echo `duplex_turn.ends_this_turn` arms itself on.
#
# Captured from claude 2.1.273. A run that disagrees means the echo changed shape; read the raw
# stream in $OUT before changing `claude_stream_json.lua`.
set -u

if [ "${VIBING_PERF:-}" != "1" ]; then
  echo "tests/perf/duplex_foreign_turn_end.sh spends real tokens; set VIBING_PERF=1 to run it." >&2
  exit 0
fi

OUT="${VIBING_PERF_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
echo "raw stream: $OUT/stream.jsonl"

cat > "$OUT/drive.py" <<'PYEOF'
"""Drive one resident `claude` over stream-json stdin and record every line it answers with."""
import json, os, subprocess, sys, threading, time

OUT = os.environ["OUT"]
ARGV = ["claude", "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
        "--input-format", "stream-json", "--permission-mode", "bypassPermissions"]

proc = subprocess.Popen(ARGV, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True, bufsize=1, cwd=OUT)
start = time.time()
log = open(os.path.join(OUT, "stream.jsonl"), "w")
lock = threading.Lock()
notified = threading.Event()


def record(obj):
    with lock:
        log.write(json.dumps(obj) + "\n")
        log.flush()


def read_stdout():
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        record({"t": round(time.time() - start, 3), "line": line})
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        # Only a top-level task wakes the parent; one owned by a subagent wakes the subagent.
        if (msg.get("type") == "system" and msg.get("subtype") == "task_notification"
                and not msg.get("owned_by_subagent")):
            notified.set()


threading.Thread(target=read_stdout, daemon=True).start()


def send(uuid, text):
    with lock:
        proc.stdin.write(json.dumps(
            {"type": "user", "uuid": uuid, "message": {"role": "user", "content": text}}) + "\n")
        proc.stdin.flush()
        log.write(json.dumps({"t": round(time.time() - start, 3), "sent": uuid}) + "\n")
        log.flush()


def interrupt():
    with lock:
        proc.stdin.write(json.dumps(
            {"type": "control_request", "request_id": "vibing-interrupt-1",
             "request": {"subtype": "interrupt"}}) + "\n")
        proc.stdin.flush()


# Cell 1: an ordinary prompt.
send("cell-1-ordinary", "reply with exactly the word ALPHA and nothing else")
time.sleep(15)

# Cell 2: a slash command. The CLI spends half a minute inside this one.
send("cell-2-compact", "/compact")
time.sleep(90)

# Cell 3: a turn long enough to interrupt.
send("cell-3-interrupted",
     "Write 60 numbered haiku, one after another, with a blank line between them. Write all 60.")
time.sleep(10)
interrupt()
time.sleep(20)

# Cell 4: the CLI's own turn. Launch a background subagent and write nothing afterwards, so the
# only thing that can produce a `result` is the notification the CLI delivers to itself.
send("cell-4-launch",
     "Use the Agent tool with run_in_background: true and subagent_type general-purpose to launch "
     "ONE subagent whose entire task is to reply with the single word PONG. Immediately after the "
     "tool call returns, end your turn with the text 'launched'. Do not wait, do not call TaskOutput.")
notified.wait(timeout=300)
time.sleep(30)

proc.stdin.close()
proc.terminate()
PYEOF

OUT="$OUT" python3 "$OUT/drive.py"

echo
echo "=== every result, and which prompt it says it answers ==="
OUT="$OUT" python3 - <<'PYEOF'
import json, os, sys

path = os.path.join(os.environ["OUT"], "stream.jsonl")
results, acks = [], []
for raw in open(path):
    row = json.loads(raw)
    if "line" not in row:
        continue
    msg = json.loads(row["line"])
    if msg.get("type") == "result":
        results.append((row["t"], msg.get("subtype"), "user_message_uuid" in msg,
                        msg.get("user_message_uuid")))
    elif msg.get("type") == "command_lifecycle":
        acks.append((row["t"], msg.get("state"), msg.get("command_uuid")))

for t, subtype, present, uuid in results:
    print(f"{t:>9}  result {str(subtype):<24} field={'yes' if present else 'NO '}  uuid={uuid!r}")
print()
print("=== command_lifecycle (emitted only when the prompt carried a uuid) ===")
for t, state, uuid in acks:
    print(f"{t:>9}  {str(state):<12} {uuid!r}")

ours = [uuid for _, _, present, uuid in results if present]
foreign = [r for r in results if not r[2]]
print()
print(f"results carrying a prompt uuid: {len(ours)} -> {ours}")
print(f"results carrying none:          {len(foreign)}")
ok = len(ours) >= 3 and len(foreign) >= 1
print("VERDICT:", "as measured for 2.1.273" if ok else "DIFFERENT -- read the raw stream before changing the decoder")
sys.exit(0 if ok else 1)
PYEOF
