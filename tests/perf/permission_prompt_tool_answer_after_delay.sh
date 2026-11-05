#!/bin/bash
# Is a *delayed* answer from a `--permission-prompt-tool` MCP tool still acted on by claude?
#
# Run with:
#   VIBING_PERF=1 tests/perf/permission_prompt_tool_answer_after_delay.sh [delay_sec]
#
# **This spends real tokens** (two haiku turns). The cost is nearly independent of the delay -- the
# model is not running while the tool call is open -- so a longer delay buys wall clock, not money.
#
# ## What this measures, and what it does not
#
# The prompt tool is the channel claude uses for the questions its own gate asks a human, such as
# an edit inside a `--plugin-dir` directory ("which is a sensitive file"). It is a fourth channel:
# `hook.measured_wait_floor_sec` times a PreToolUse hook blocking, and the 1800s MCP ceiling in
# `handbook/architecture/approval-without-kill.md` was measured against a server that **never**
# answers. Neither says whether an answer that arrives late is still consumed, which is what the
# arm here times. The figure it produces is `native_approval.measured_wait_floor_sec` on the claude
# descriptor.
#
# ## Why the delay is the production value
#
# This produces a **floor**: "a decision this late was still acted on". The default is the whole
# budget vibing.nvim can hold a native prompt open for (`wait_budget.native_approval_budget_sec()`,
# 900 + 60), so what survives the cell is the budget itself.
#
# ## The reading
#
# Three signals per cell, never collapsed into one verdict:
#
#   1. was the prompt tool consulted   (the probe's log has a CONSULTED line)
#   2. did the probe answer            (the probe's log has an ANSWERED line)
#   3. did the approved edit RUN       (the cell's target file reads `bye`)
#
# Signal 3 is the one the plumbing cannot fake. Signal 1 failing means the cell measured nothing.
# The control cell answers immediately; without it a failing arm has two possible authors.
set -u

if [ "${VIBING_PERF:-}" != "1" ]; then
  echo "tests/perf/permission_prompt_tool_answer_after_delay.sh spends real tokens; set VIBING_PERF=1." >&2
  exit 0
fi

DELAY="${1:-960}"
OUT="${VIBING_PERF_OUT:-$(mktemp -d)}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODULES="$ROOT/agent-plugin/mcp-server/node_modules"
mkdir -p "$OUT"

cat > "$OUT/probe.mjs" <<EOF
import { McpServer } from "$MODULES/@modelcontextprotocol/sdk/dist/esm/server/mcp.js";
import { StdioServerTransport } from "$MODULES/@modelcontextprotocol/sdk/dist/esm/server/stdio.js";
import { z } from "$MODULES/zod/index.js";
import fs from "node:fs";

const log = (line) => fs.appendFileSync(process.env.PROBE_LOG, \`\${new Date().toISOString()} \${line}\n\`);
const server = new McpServer({ name: "probe", version: "0.0.1" });
server.tool(
  "approve",
  { tool_name: z.string(), input: z.any(), tool_use_id: z.string().optional() },
  async (args) => {
    log(\`CONSULTED \${args.tool_name} \${args.input?.file_path ?? ""}\`);
    await new Promise((resolve) => setTimeout(resolve, Number(process.env.PROBE_DELAY_SEC) * 1000));
    log("ANSWERED allow");
    return { content: [{ type: "text", text: JSON.stringify({ behavior: "allow", updatedInput: args.input }) }] };
  }
);
await server.connect(new StdioServerTransport());
EOF

run_cell() {
  local name="$1" delay="$2"
  local dir="$OUT/$name"
  local plugin="$dir/.vibing/plugins/p"
  local target="$plugin/skills/write/references/paragraph.md"
  mkdir -p "$plugin/.claude-plugin" "$(dirname "$target")"
  git -C "$dir" init -q
  echo '{"name":"p","version":"0.0.1"}' > "$plugin/.claude-plugin/plugin.json"
  echo hello > "$target"
  : > "$dir/probe.log"
  cat > "$dir/mcp.json" <<JSON
{"mcpServers":{"probe":{"command":"node","args":["$OUT/probe.mjs"],"env":{"PROBE_LOG":"$dir/probe.log","PROBE_DELAY_SEC":"$delay"}}}}
JSON

  local started=$SECONDS
  (cd "$dir" && echo "Use the Edit tool to replace 'hello' with 'bye' in $target. Do nothing else." \
    | claude -p --model haiku --output-format json --permission-mode default \
      --plugin-dir "$plugin" --mcp-config "$dir/mcp.json" \
      --permission-prompt-tool mcp__probe__approve \
      --allowedTools "Read,Edit" --disallowedTools mcp__probe__approve > "$dir/out.json" 2>&1)
  local elapsed=$((SECONDS - started))

  local consulted answered ran
  consulted=$(grep -c CONSULTED "$dir/probe.log")
  answered=$(grep -c ANSWERED "$dir/probe.log")
  ran=$([ "$(cat "$target")" = "bye" ] && echo yes || echo no)
  echo "$name delay=${delay}s elapsed=${elapsed}s consulted=$consulted answered=$answered edit_ran=$ran"
}

echo "claude $(claude --version 2>/dev/null)"
echo "logs: $OUT"
run_cell control 0
run_cell delayed "$DELAY"
