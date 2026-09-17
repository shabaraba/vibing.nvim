#!/bin/bash
# Can a PreToolUse hook that says `defer` hand the final decision to `--permission-prompt-tool`,
# and does the user's own settings.json deny still apply on the way? (#778, decision 1)
#
# Run with:
#   VIBING_PERF=1 tests/perf/permission_prompt_tool.sh            # both cells
#   VIBING_PERF=1 tests/perf/permission_prompt_tool.sh allow      # cell 1 only
#   VIBING_PERF=1 tests/perf/permission_prompt_tool.sh deny       # cell 2 only
#
# **This spends real tokens.** Two short turns on haiku.
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
# question — if the CLI will ask us. That is what this measures. It is not the mechanism the
# handbook's "Why not `--permission-prompt-tool stdio`" section rejected: that one was the
# stream-json `control_request{can_use_tool}`, rejected because pre-allowed tools never reach it.
# Here we *want* only the non-pre-allowed ones, so the rejection does not carry over. What does
# carry over is that none of this is measured yet.
#
# Three things have to be true at once, and each cell fails differently:
#
#   1. hooks and `--permission-prompt-tool` coexist. If the CLI refuses the combination, or drops
#      one of them, cell 1 shows the prompt tool never called.
#   2. a tool the hook deferred, and `--allowedTools` does not cover, actually reaches the prompt
#      tool. Cell 1 shows the call in the MCP server's log.
#   3. the user's own deny still wins. Cell 2 sets `permissions.deny: ["Write"]` in the settings
#      the CLI loads and expects the prompt tool to be **not called** and the file **not written**.
#      If the prompt tool is called there, the gate asks before it denies, and answering `allow`
#      would override the user's rule — which is B's cost, reappearing inside C.
#
# The verdict is the probe file on disk, never what the CLI says about itself: `probe-out.txt`
# exists iff the Write ran.
#
# The flag's argument is an **MCP tool name**, not a transport. That is read off the binary's own
# error strings ("tool ... (passed via --permission-prompt-tool) must be an MCP tool"), which is a
# hypothesis and not evidence — if cell 1 reports the flag rejected, that reading was wrong and the
# argument shape is the first thing to re-check.
set -u

if [ "${VIBING_PERF:-}" != "1" ]; then
  echo "tests/perf/permission_prompt_tool.sh spends real tokens; set VIBING_PERF=1 to run it." >&2
  exit 0
fi

CELL="${1:-both}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/.vibing/probe/permission-prompt-tool"
mkdir -p "$OUT"

# An MCP server with one tool, which logs every call and always allows. Always-allow is right for
# the measurement: what is being asked is *whether we are consulted*, and a deny would confuse
# "the CLI never asked" with "the CLI asked and we said no".
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
    // The whole point of the run: was this reached, and with what.
    log(`CALLED ${JSON.stringify(req.params ?? {})}`);
    send({
      jsonrpc: '2.0',
      id: req.id,
      result: {
        content: [{ type: 'text', text: JSON.stringify({ behavior: 'allow', updatedInput: req.params?.arguments?.input ?? {} }) }],
      },
    });
    return;
  }
  if (req.id !== undefined) send({ jsonrpc: '2.0', id: req.id, result: {} });
});
EOF

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

run_cell() {
  local name="$1" deny="$2"
  local dir="$OUT/$name"
  rm -rf "$dir"
  mkdir -p "$dir"

  export PROMPT_TOOL_LOG="$dir/prompt-tool.log"
  export HOOK_LOG="$dir/hook.log"
  : > "$PROMPT_TOOL_LOG"
  : > "$HOOK_LOG"

  local settings
  settings=$(cat <<EOF
{"permissions":{"deny":$deny},
 "hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"HOOK_LOG=$HOOK_LOG bash $OUT/defer-hook.sh","timeout":60}]}]}}
EOF
)
  local mcp
  mcp=$(cat <<EOF
{"mcpServers":{"probe":{"command":"node","args":["$OUT/prompt_server.mjs"],"env":{"PROMPT_TOOL_LOG":"$PROMPT_TOOL_LOG"}}}}
EOF
)

  echo "=== cell $name (settings deny: $deny) ==="
  ( cd "$dir" && claude -p \
      --output-format stream-json --verbose \
      --model claude-haiku-4-5-20251001 \
      --permission-mode default \
      --strict-mcp-config --setting-sources project \
      --mcp-config "$mcp" \
      --permission-prompt-tool "mcp__probe__approve" \
      --allowedTools "Read" \
      --settings "$settings" \
      "Use the Write tool to create probe-out.txt containing exactly: ok. Then stop." \
      > "$dir/stream.jsonl" 2>"$dir/stderr.log" )
  echo "CLI exit=$?"

  # **Three signals, reported separately and never collapsed into one verdict.** "The prompt tool
  # was not called AND the tool did not run" and "the prompt tool was called, and the gate denied
  # afterwards" are different facts with the same-looking outcome, and reading one as the other is
  # the confound that produced a wrong reading of the 950s copilot cell (the gate's refusal read as
  # the hook's). Signal 1 is the control: without it the other two say nothing, because the hook
  # never ran.
  local hook_fired prompt_calls tool_ran
  hook_fired=$(grep -c 'HOOK DEFER' "$HOOK_LOG" || true)
  prompt_calls=$(grep -c 'CALLED' "$PROMPT_TOOL_LOG" || true)
  if [ -f "$dir/probe-out.txt" ]; then tool_ran=yes; else tool_ran=no; fi

  echo "1. hook wrote defer:      $hook_fired"
  echo "2. prompt tool called:    $prompt_calls"
  echo "3. tool ran:              $tool_ran"

  # Say what each combination means here rather than in the reader's head. Nothing below is a
  # measurement; it is the mapping decided before the run, printed next to what was measured.
  if [ "$hook_fired" -eq 0 ]; then
    echo "   READING: measurement failed -- the hook never ran, so 2 and 3 are about something else."
  elif [ "$prompt_calls" -eq 0 ]; then
    echo "   READING: the gate settled it before the prompt tool. Whatever denied it ran FIRST."
  elif [ "$tool_ran" = "no" ]; then
    echo "   READING: the prompt tool WAS consulted and the call was still refused afterwards."
  else
    echo "   READING: the prompt tool was consulted and its allow decided the outcome."
  fi
  echo "logs: $dir"
}

# Cell 1: nothing in the user's deny list. Expect hook=1, prompt tool called, the tool ran.
# Anything else means the combination does not work and decision 1 is B.
if [ "$CELL" = "both" ] || [ "$CELL" = "allow" ]; then
  run_cell allow "[]"
fi

# Cell 2: the user denies Write. What the four readings mean for decision 1:
#
#   hook=0                      -> measurement failed, re-run.
#   prompt tool not called      -> the deny ran first. **The third shape is safe**: deferring keeps
#                                  the user's settings.json rules, and only what survives them is
#                                  ever put to us.
#   called, tool did not run    -> we are consulted before the deny is applied. Safe here only
#                                  because we would have answered allow and something else refused
#                                  it; what an allow does in general still needs its own run.
#   called, tool ran            -> our allow overrode the user's own deny. The third shape is B
#                                  with extra steps, and decision 1 is B.
if [ "$CELL" = "both" ] || [ "$CELL" = "deny" ]; then
  run_cell deny '["Write"]'
fi

exit 0
