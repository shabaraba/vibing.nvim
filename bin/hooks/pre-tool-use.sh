#!/bin/bash
# vibing.nvim pre-tool-use hook
# Communicates with Neovim RPC server to check tool permissions

LOG="/tmp/vibing-hook-debug.log"
echo "$(date) hook fired, PID=$$, PORT=${VIBING_NVIM_RPC_PORT:-UNSET}" >> "$LOG"

INPUT=$(cat)
PORT="${VIBING_NVIM_RPC_PORT}"

echo "$(date) tool=$(echo "$INPUT" | grep -o '"tool_name":"[^"]*"' | head -1)" >> "$LOG"

# No RPC port = not running inside vibing.nvim, allow everything
if [ -z "$PORT" ]; then
  echo "$(date) no PORT, allowing" >> "$LOG"
  exit 0
fi

REQUEST_ID="$$"
COMM_DIR="/tmp/vibing-hook-${PORT}"
mkdir -p "$COMM_DIR" 2>/dev/null

REQ_FILE="$COMM_DIR/${REQUEST_ID}.req"
RES_FILE="$COMM_DIR/${REQUEST_ID}.res"

# Write request file (atomic via rename)
echo "$INPUT" > "${REQ_FILE}.tmp"
mv "${REQ_FILE}.tmp" "$REQ_FILE"

# Notify Neovim RPC server (fire-and-forget)
printf '{"method":"check_tool_permission","id":1,"params":{"request_id":"%s"}}\n' "$REQUEST_ID" \
  | nc -w 1 127.0.0.1 "$PORT" >/dev/null 2>&1
NC_STATUS=$?
echo "$(date) nc status=$NC_STATUS, waiting for $RES_FILE" >> "$LOG"

# Poll for response file (max 120 seconds)
ELAPSED=0
MAX_WAIT=1200
while [ ! -f "$RES_FILE" ] && [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  sleep 0.1
  ELAPSED=$((ELAPSED + 1))
done

if [ -f "$RES_FILE" ]; then
  RESPONSE=$(cat "$RES_FILE")
  echo "$(date) got response: $RESPONSE" >> "$LOG"
  rm -f "$REQ_FILE" "$RES_FILE" 2>/dev/null

  # Check if decision is deny → exit 2 with reason on stderr
  DECISION=$(echo "$RESPONSE" | grep -o '"permissionDecision":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [ "$DECISION" = "deny" ]; then
    REASON=$(echo "$RESPONSE" | grep -o '"permissionDecisionReason":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "$(date) DENY: $REASON" >> "$LOG"
    echo "${REASON:-Denied by vibing.nvim}" >&2
    exit 2
  fi

  echo "$(date) ALLOW" >> "$LOG"
  exit 0
fi

# Timeout - clean up and allow by default
echo "$(date) TIMEOUT after ${ELAPSED}0ms, allowing" >> "$LOG"
rm -f "$REQ_FILE" 2>/dev/null
exit 0
