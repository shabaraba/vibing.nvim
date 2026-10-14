"""Reproduce the #861 assertion mutations against live sources, restoring every byte.

Run from the worktree: python3 tests/fixtures/codex-native-approval/mutations.py
Add --e2e for the two real-token controls (requires explicit E2E authorization).
"""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
MODULES = "lua/vibing/infrastructure/adapter/modules/"
SPEC = "tests/lua/infrastructure/adapter/codex_duplex_spec.lua"
OUTPUT = ROOT / ".vibing/probe/native-approval-mutations"
OUTPUT.mkdir(parents=True, exist_ok=True)
MUTATIONS = [
    ("thread-owner", "codex_native_approval.lua",
     "params.threadId and params.threadId ~= rpc.thread_id", "false", SPEC),
    ("turn-owner", "codex_native_approval.lua",
     "params.turnId and params.turnId ~= rpc.turn_id", "false", SPEC),
    ("early-request", "codex_duplex_protocol.lua",
     "if rpc.starting_turn and p.turnId and", "if false and p.turnId and", SPEC),
    ("replay-request", "codex_duplex_protocol.lua",
     "M.process_line(record, vim.json.encode(msg))", "-- request replay removed", SPEC),
    ("cancel-option", "codex_native_decisions.lua",
     'local IMPLIED = { "accept", M.DECLINE, "cancel" }',
     'local IMPLIED = { "accept", M.DECLINE }',
     "tests/lua/infrastructure/adapter/codex_native_decisions_spec.lua"),
    ("file-cancel-option", "codex_native_decisions.lua",
     'local IMPLIED = { "accept", M.DECLINE, "cancel" }',
     'local IMPLIED = { "accept", M.DECLINE }', SPEC),
    ("cancel-wire", "codex_native_approval.lua",
     "result = { decision = decision }", 'result = { decision = "decline" }', SPEC),
]
if "--e2e" in sys.argv:
    MUTATIONS = [
        ("human-reply", "codex_native_approval.lua",
         "result = { decision = decision }", 'result = { decision = "decline" }',
         "tests/e2e/codex_native_approval_spec.lua"),
        ("premature-reply", "codex_native_approval.lua",
         "function M.auto_approve_enabled()\n", "function M.auto_approve_enabled()\n  do return true end\n",
         "tests/e2e/codex_native_approval_spec.lua"),
    ]

for name, module, original, replacement, spec in MUTATIONS:
    source = ROOT / MODULES / module
    snapshot = source.read_bytes()
    backup = OUTPUT / f"{name}.source.lua"
    backup.write_bytes(snapshot)
    text = snapshot.decode()
    if text.count(original) != 1:
        raise SystemExit(f"REFUSED {name}: expected exactly one mutation target")
    try:
        source.write_text(text.replace(original, replacement))
        env = dict(os.environ)
        if "--e2e" in sys.argv:
            env["VIBING_E2E"] = "1"
        command = ["nvim", "--headless", "-u", "tests/minimal_init.lua", "-c",
                   f"PlenaryBustedDirectory {spec} {{ minimal_init = 'tests/minimal_init.lua', timeout = 240000 }}"]
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=250)
        output = result.stdout + result.stderr
        (OUTPUT / f"{name}.log").write_text(output)
        if result.returncode == 0 or "Fail" not in output:
            raise SystemExit(f"SURVIVED or no failing assertion: {name}\n{output}")
        print(f"KILLED {name} (exit {result.returncode})", flush=True)
        for line in output.splitlines():
            if "Fail\x1b" in line or "Timed out" in line or "expected" in line:
                print(line, flush=True)
    finally:
        source.write_bytes(backup.read_bytes())
        if source.read_bytes() != snapshot:
            raise SystemExit(f"RESTORE FAILED: {source}")
