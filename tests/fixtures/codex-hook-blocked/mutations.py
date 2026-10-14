"""Source mutations for #862. Restores byte-for-byte backups even on failure.

Unit mode spends no tokens. --mode e2e requires explicitly authorized real Codex use.
Each run selects one existing scenario; no assertions or spec files are mutated.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
DECODER = "lua/vibing/infrastructure/adapter/decoders/codex_app_server.lua"
RENDERER = "lua/vibing/infrastructure/adapter/modules/event_renderer.lua"
PROTOCOL = "lua/vibing/infrastructure/adapter/modules/codex_duplex_protocol.lua"
ADAPTER = "lua/vibing/infrastructure/adapter/cli_adapter.lua"
PERMISSION = "lua/vibing/infrastructure/rpc/handlers/permission.lua"
DECISIONS = "lua/vibing/application/chat/approval_decision.lua"
BUFFER = "lua/vibing/presentation/chat/buffer.lua"
DSPEC = "tests/lua/infrastructure/adapter/modules/codex_app_server_decoder_spec.lua"
RSPEC = "tests/lua/infrastructure/adapter/modules/event_renderer_spec.lua"
PSPEC = "tests/lua/infrastructure/adapter/codex_duplex_spec.lua"
HSPEC = "tests/lua/infrastructure/rpc/handlers/permission_decision_spec.lua"
ASPEC = "tests/lua/application/chat/approval_delegate_integration_spec.lua"
ESPEC = "tests/e2e/codex_hook_blocked_spec.lua"

# id, source, original, replacement, spec, selected scenario
MUTATIONS = [
    ("U01", DECODER, 'method == "hook/started"', 'method == "unused/hookStarted"', DSPEC, "recognizes a started hook as proof of a live process"),
    ("U02", DECODER, 'method == "hook/completed"', 'method == "unused/hookCompleted"', DSPEC, "surfaces every feedback entry without inventing an approval"),
    ("U03", DECODER, 'run.status ~= "blocked"', 'false', DSPEC, "ignores unknown statuses, other hook events and malformed runs"),
    ("U04", DECODER, 'run.eventName ~= "preToolUse"', 'false', DSPEC, "ignores unknown statuses, other hook events and malformed runs"),
    ("U05", DECODER, 'type(run) ~= "table"', 'false', DSPEC, "ignores unknown statuses, other hook events and malformed runs"),
    ("U06", DECODER, 'table.insert(reasons, entry.text)', 'reasons[1] = entry.text', DSPEC, "surfaces every feedback entry without inventing an approval"),
    ("U07", DECODER, 'unavailable = true', 'unavailable = false', DSPEC, "marks the script's connection and timeout failures as unavailable"),
    ("U08", DECODER, 'table.insert(reasons, run.statusMessage)', '-- status message dropped', DSPEC, "uses statusMessage and then a fallback when feedback is absent"),
    ("U09", DECODER, 'The hook supplied no reason.', 'missing', DSPEC, "uses statusMessage and then a fallback when feedback is absent"),
    ("U10", DECODER, 'run.id:match(":([^:]+)$")', 'nil', DSPEC, "uses captured RPC inputs to identify blocked calls and forgets completed hooks"),
    ("U11", DECODER, 'state.hook_inputs[item_id] = nil', '-- retained', DSPEC, "uses captured RPC inputs to identify blocked calls and forgets completed hooks"),
    ("U12", DECODER, 'name = call and call.name', 'name = nil', DSPEC, "uses captured RPC inputs to identify blocked calls and forgets completed hooks"),
    ("U13", DECODER, 'input = call and call.input', 'input = nil', DSPEC, "uses captured RPC inputs to identify blocked calls and forgets completed hooks"),
    ("U14", RENDERER, 'handlers.hook_blocked = function(event, context)', 'handlers.unused_hook_blocked = function(event, context)', RSPEC, "streams a hook refusal as a notice, keeping feedback headings inside it"),
    ("U15", RENDERER, 'event.reason:gsub("\\n", "\\n  ")', 'event.reason', RSPEC, "streams a hook refusal as a notice, keeping feedback headings inside it"),
    ("U16", RENDERER, 'if event.unavailable then', 'if false then', RSPEC, "explains why approval cannot fix an unavailable hook"),
    ("U17", RENDERER, 'if event.name then', 'if false then', RSPEC, "identifies a blocked call without reporting it as an executed tool"),
    ("U18", RENDERER, 'local target = "this call"', 'context._tools = {}; local target = "this call"', RSPEC, "identifies a blocked call without reporting it as an executed tool"),
    ("U19", RENDERER, 'handlers.hook_blocked = function(event, context)', 'handlers.hook_blocked = function(event, context) table.insert(context.errorOutput, event.reason)', RSPEC, "streams a hook refusal as a notice, keeping feedback headings inside it"),
    ("U20", PROTOCOL, 'retry_hook_approval = true', 'retry_hook_approval = false', PSPEC, "enables hook retry options only for a resident turn"),
    ("U21", PROTOCOL, 'value = "deny_once"', 'value = "deny_for_session"', PSPEC, "enables hook retry options only for a resident turn"),
    ("U22", ADAPTER, '_retry_hook_approval = process_model == "duplex"', '_retry_hook_approval = true', "tests/lua/infrastructure/adapter/codex_cli_spec.lua", "does not enable duplex hook retry policy for codex exec"),
    ("U23", PROTOCOL, 'p.threadId and p.threadId ~= rpc.thread_id', 'false', PSPEC, "filters foreign hook notifications and renders the owned block immediately"),
    ("U24", PROTOCOL, 'not record._turn or id ~= rpc.turn_id', 'not record._turn', PSPEC, "filters foreign hook notifications and renders the owned block immediately"),
    ("U25", PROTOCOL, 'record._turn.turn_id ~= scope.turn_id', 'false', PSPEC, "observes only the current turn's hook input and clears it on the next turn"),
    ("U26", PROTOCOL, 'state.hook_inputs[id] = { name = tool, input = input }', '-- input discarded', PSPEC, "observes only the current turn's hook input and clears it on the next turn"),
    ("U27", PROTOCOL, 'record.decoder_state.hook_inputs = nil', '-- no reset', PSPEC, "observes only the current turn's hook input and clears it on the next turn"),
    ("U28", PERMISSION, 'if active_opts and active_opts._retry_hook_approval then', 'if false then', HSPEC, "releases a retry hook before asking with its actual input, without cancelling"),
    ("U29", PERMISSION, 'write_hook_response(request_id, "deny", reason)\n      local options', '-- no response\n      local options', HSPEC, "releases a retry hook before asking with its actual input, without cancelling"),
    ("U30", PERMISSION, 'requires manual approval in the chat', 'does not need approval', HSPEC, "releases a retry hook before asking with its actual input, without cancelling"),
    ("U31", PERMISSION, 'local options = active_opts._hook_approval_options or APPROVAL_OPTIONS', 'cancel_turn(scope.entry); local options = active_opts._hook_approval_options or APPROVAL_OPTIONS', HSPEC, "releases a retry hook before asking with its actual input, without cancelling"),
    ("U32", PERMISSION, 'tool_input,\n            options,\n            request_id,\n            nil,', '{},\n            options,\n            request_id,\n            nil,', HSPEC, "releases a retry hook before asking with its actual input, without cancelling"),
    ("U33", PERMISSION, 'local options = active_opts._hook_approval_options or APPROVAL_OPTIONS', 'local options = APPROVAL_OPTIONS', HSPEC, "releases a retry hook before asking with its actual input, without cancelling"),
    ("U34", PERMISSION, 'tool_input,\n            options,\n            request_id,\n            nil,', 'tool_input, options, "wrong", nil,', HSPEC, "releases a retry hook before asking with its actual input, without cancelling"),
    ("U35", PERMISSION, 'tool_input,\n            options,\n            request_id,\n            nil,', 'tool_input,\n            options,\n            request_id,\n            true,', HSPEC, "releases a retry hook before asking with its actual input, without cancelling"),
    ("U36", PERMISSION, 'turn.turn_id == turn_id and', '', HSPEC, "does not send a deferred retry prompt to a replacement turn"),
    ("U37", PERMISSION, 'elseif result.behavior == "deny" then', 'elseif false then', HSPEC, "never turns an explicit deny into a retry approval"),
    ("U38", BUFFER, 'entry.kind == ApprovalDecision.HOOK_RETRY_KIND', 'false', ASPEC, "keeps a retry answer unspent while a native approval holds the turn open"),
    ("U39", BUFFER, 'the retry approval is still pending.', 'retry discarded.', ASPEC, "keeps a retry answer unspent while a native approval holds the turn open"),
    ("U40", DECISIONS, 'chat_buf:clear_pending_approval(pending.request_id)', '-- retained prompt', ASPEC, "answers a resident hook retry through the MCP handler without persisting permissions"),
    ("U41", DECISIONS, 'M.input_summary(tool, input)\n    )', '""\n    )', ASPEC, "answers a resident hook retry through the MCP handler without persisting permissions"),
    ("U42", BUFFER, 'handle_once_permission(self, tool, self._session_allow)', 'handle_session_permission(self, tool, true)', ASPEC, "answers a resident hook retry through the MCP handler without persisting permissions"),
    ("U43", DECODER, 'method == "item/agentMessage/delta"', 'method == "unused/delta"', DSPEC, "ignores unknown statuses, other hook events and malformed runs"),
    ("U44", PERMISSION, 'require("vibing.application.chat.approval_decision").HOOK_RETRY_KIND', 'nil', HSPEC, "releases a retry hook before asking with its actual input, without cancelling"),
    ("U45", ADAPTER, '_hook_approval_options = process_model == "duplex"', '_hook_approval_options = true', "tests/lua/infrastructure/adapter/codex_cli_spec.lua", "does not enable duplex hook retry policy for codex exec"),
    ("U46", ADAPTER, '_observe_hook_input = process_model == "duplex"', '_observe_hook_input = true', "tests/lua/infrastructure/adapter/codex_cli_spec.lua", "does not enable duplex hook retry policy for codex exec"),
    ("U47", PERMISSION, 'active_opts._observe_hook_input(scope, hook_input, tool_name, tool_input)', '-- no observation', HSPEC, "observes the same owning turn and input that the permission gate evaluates"),
    ("E01", PERMISSION, 'write_hook_response(request_id, "deny", result.message)', 'write_hook_response(request_id, "defer", result.message)', ESPEC, "shows a denied call with its reason and offers no permission override"),
    ("E05", PERMISSION, 'if active_opts and active_opts._retry_hook_approval then', 'if false then', ESPEC, "continues the same operation after a chat allow_once answer"),
    ("E06", BUFFER, 'handle_once_permission(self, tool, self._session_allow)', '-- no grant', ESPEC, "continues the same operation after a chat allow_once answer"),
    ("E10", "bin/hooks/pre-tool-use.sh", 'rm -f "$REQ_FILE" 2>/dev/null\n  exit 2', 'rm -f "$REQ_FILE" 2>/dev/null\n  exit 0', ESPEC, "reports an unreachable RPC server without offering an approval"),
]


def run_case(spec, case, output, real):
    env = os.environ.copy()
    env["VIBING_HOOK_TEST_CASE"] = case
    env["VIBING_E2E"] = "1" if real else "0"
    command = ["nvim", "--headless", "-u", "tests/minimal_init.lua", "-c",
               f"PlenaryBustedDirectory {spec} {{ minimal_init = 'tests/fixtures/codex-hook-blocked/filter_init.lua', timeout = 240000 }}"]
    result = subprocess.run(command, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=250)
    output.write_text(result.stdout)
    clean = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)
    ran = re.findall(r"(Success|Fail)\s*\|\|\s*([^\n]+)", clean)
    assert len(ran) == 1 and case in ran[0][1], f"scenario was not exercised: {output}"
    return result.returncode, ran[0][0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["unit", "e2e"], default="unit")
    parser.add_argument("--only", default="")
    parser.add_argument("--out", default="/private/tmp/issue862-mutations")
    args = parser.parse_args()
    output = Path(args.out)
    output.mkdir(parents=True, exist_ok=True)
    selected = [m for m in MUTATIONS if m[0].startswith("E" if args.mode == "e2e" else "U")
                and (not args.only or m[0] in args.only.split(","))]
    assert selected, "no mutations selected"
    results = []
    baseline = set()
    with tempfile.TemporaryDirectory(prefix="issue862-backup-") as scratch:
        for identity, source, old, new, spec, case in selected:
            real = identity.startswith("E")
            # Real baselines are run separately to avoid paying for unchanged scenarios repeatedly.
            if not real and (spec, case) not in baseline:
                code, verdict = run_case(spec, case, output / f"{identity}-baseline.log", False)
                assert code == 0 and verdict == "Success", "baseline must pass first"
                baseline.add((spec, case))
            path = ROOT / source
            original = path.read_bytes()
            backup = Path(scratch) / identity
            backup.write_bytes(original)
            text = original.decode()
            assert old in text, f"mutation target absent: {identity}"
            try:
                path.write_text(text.replace(old, new, 1))
                code, verdict = run_case(spec, case, output / f"{identity}.log", real)
                killed = code != 0 and verdict == "Fail"
                row = {"id": identity, "source": source, "killed": killed, "scenario": case}
                results.append(row)
                print(json.dumps(row), flush=True)
            finally:
                path.write_bytes(backup.read_bytes())
                assert path.read_bytes() == original
    (output / f"{args.mode}-results.json").write_text(json.dumps(results, indent=2) + "\n")
    assert all(row["killed"] for row in results), "a mutation survived"


if __name__ == "__main__":
    main()
