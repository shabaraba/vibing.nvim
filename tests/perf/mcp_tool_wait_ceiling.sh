#!/bin/bash
# How long will the CLI wait for an MCP tool to answer? (#778)
#
# Run with:
#   VIBING_PERF=1 tests/perf/mcp_tool_wait_ceiling.sh [seconds]
#
# **This spends real tokens.** Same category as `hook_wait_ceiling.sh` and excluded from `npm test`
# for the same reason.
#
# This is a *different* ceiling from the hook's, and `nvim_ask_user_question` is the thing that
# sits on it. That tool never goes through PreToolUse -- it is vibing.nvim's own MCP tool, answered
# by the RPC server -- so raising the hook timeout buys it nothing. Without this number, "the
# approval prompt can wait an hour but a question asked through the MCP route dies at some other
# limit" is a difference nobody would predict and everybody would have to debug.
#
# The stub server answers `initialize` and `tools/list` normally and then simply never answers the
# call, so what is timed is purely the CLI's patience. Watch `tool_progress` heartbeats in the
# stream: the CLI reports `elapsed_time_seconds` while it waits, which is how the ceiling is read
# off even when the run is cut short externally.
set -u

if [ "${VIBING_PERF:-}" != "1" ]; then
  echo "tests/perf/mcp_tool_wait_ceiling.sh spends real tokens; set VIBING_PERF=1 to run it." >&2
  exit 0
fi

BUDGET="${1:-1800}"
OUT="${VIBING_PERF_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
LOG="$OUT/mcp-wait.log"
: > "$LOG"

cat > "$OUT/never_answers_server.mjs" <<'EOF'
// Minimal stdio MCP server exposing one tool that never returns a result.
import { createInterface } from 'node:readline';

const send = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');

createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return;
  let req;
  try { req = JSON.parse(line); } catch { return; }

  if (req.method === 'initialize') {
    send({ jsonrpc: '2.0', id: req.id, result: {
      protocolVersion: '2024-11-05',
      capabilities: { tools: {} },
      serverInfo: { name: 'never-answers', version: '1.0.0' },
    }});
  } else if (req.method === 'tools/list') {
    send({ jsonrpc: '2.0', id: req.id, result: { tools: [{
      name: 'wait_forever',
      description: 'Blocks until the caller gives up. Call this when asked to.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    }]}});
  } else if (req.method === 'tools/call') {
    // Deliberately no response. The CLI's own deadline is the measurement.
  } else if (req.id !== undefined) {
    send({ jsonrpc: '2.0', id: req.id, result: {} });
  }
});
EOF

stamp() { echo "$(date +%s) $(date +%H:%M:%S) $*" >> "$LOG"; }

stamp "CLI START budget=${BUDGET}s out=$OUT"

# No outer timeout: the CLI's own deadline is the thing being measured, and imposing one here would
# record it instead.
claude -p --output-format stream-json --verbose \
  --strict-mcp-config \
  --mcp-config "{\"mcpServers\":{\"probe\":{\"command\":\"node\",\"args\":[\"$OUT/never_answers_server.mjs\"]}}}" \
  --setting-sources project \
  --model claude-haiku-4-5-20251001 \
  --permission-mode bypassPermissions \
  "Call the wait_forever tool from the probe MCP server exactly once. Then stop." \
  > "$OUT/mcp-stream.jsonl" 2> "$OUT/mcp-stderr.log"
stamp "CLI EXIT code=$?"

echo
echo "=== MCP tool wait, budget ${BUDGET}s ==="
cat "$LOG"
echo "--- last heartbeat the CLI reported while waiting ---"
grep -o '"elapsed_time_seconds":[0-9]*' "$OUT/mcp-stream.jsonl" 2>/dev/null | tail -1
echo "--- how the call ended ---"
grep -o '"is_error":[a-z]*' "$OUT/mcp-stream.jsonl" 2>/dev/null | tail -1
echo
echo "Full stream: $OUT/mcp-stream.jsonl"
