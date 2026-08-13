#!/bin/bash
# vibing.nvim pre-tool-use hook
# Communicates with Neovim RPC server to check tool permissions

debug_log() {
  [ -n "$VIBING_DEBUG" ] && echo "$(date) $1" >> "/tmp/vibing-hook-debug.log"
}

debug_log "hook fired, PID=$$, PORT=${VIBING_NVIM_RPC_PORT:-UNSET}"

INPUT=$(cat)
PORT="${VIBING_NVIM_RPC_PORT}"

debug_log "tool=$(echo "$INPUT" | grep -o '"tool_name":"[^"]*"' | head -1)"

# No RPC port = not running inside vibing.nvim, allow everything
if [ -z "$PORT" ]; then
  debug_log "no PORT, allowing"
  exit 0
fi

REQUEST_ID="$(date +%s)-$$-$RANDOM"
COMM_DIR="${VIBING_HOOK_COMM_DIR:-/tmp/vibing-hook-${PORT}}"
mkdir -p "$COMM_DIR" 2>/dev/null

REQ_FILE="$COMM_DIR/${REQUEST_ID}.req"
RES_FILE="$COMM_DIR/${REQUEST_ID}.res"

# Write request file (atomic via rename)
printf '%s' "$INPUT" > "${REQ_FILE}.tmp"
mv "${REQ_FILE}.tmp" "$REQ_FILE"

# Identifies which chat buffer's stream this hook invocation belongs to (see
# ActiveStreamRegistry), so concurrent chats don't cross-wire each other's approval UI.
# Restricted to [A-Za-z0-9_] since it's interpolated directly into the JSON request below.
HANDLE_ID="${VIBING_HANDLE_ID//[^A-Za-z0-9_]/}"

# Notify Neovim RPC server (fire-and-forget)
printf '{"method":"check_tool_permission","id":1,"params":{"request_id":"%s","handle_id":"%s"}}\n' "$REQUEST_ID" "$HANDLE_ID" \
  | nc -w 1 127.0.0.1 "$PORT" >/dev/null 2>&1
NC_STATUS=$?
debug_log "nc status=$NC_STATUS, waiting for $RES_FILE"

# If nc failed to connect, fail closed (deny)
if [ "$NC_STATUS" -ne 0 ]; then
  debug_log "nc failed (status=$NC_STATUS), denying"
  echo "Failed to connect to vibing.nvim RPC server" >&2
  rm -f "$REQ_FILE" 2>/dev/null
  exit 2
fi

# Poll for response file (max 120 seconds)
ELAPSED=0
MAX_WAIT=1200
while [ ! -f "$RES_FILE" ] && [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  sleep 0.1
  ELAPSED=$((ELAPSED + 1))
done

if [ -f "$RES_FILE" ]; then
  RESPONSE=$(cat "$RES_FILE")
  debug_log "got response: $RESPONSE"
  rm -f "$REQ_FILE" "$RES_FILE" 2>/dev/null

  DECISION=$(echo "$RESPONSE" | grep -o '"permissionDecision":"[^"]*"' | head -1 | cut -d'"' -f4)

  case "$DECISION" in
    deny)
      REASON=$(echo "$RESPONSE" | grep -o '"permissionDecisionReason":"[^"]*"' | head -1 | cut -d'"' -f4)
      debug_log "DENY: $REASON"
      echo "${REASON:-Denied by vibing.nvim}" >&2
      exit 2
      ;;
    allow)
      # An explicit grant, which makes the CLI skip its own permission gate. Exiting 0 without
      # printing this is NOT a grant -- a silent exit 0 reads as "no opinion", and in headless
      # `-p` mode the gate it falls back to cannot prompt anyone, so the tool is refused (#564).
      debug_log "ALLOW (explicit grant)"
      printf '%s' "$RESPONSE"
      exit 0
      ;;
    *)
      # "defer" (and any response shape this script does not recognise): vibing.nvim permits the
      # call but leaves the CLI's own gate, and with it the user's settings.json rules, in charge.
      debug_log "DEFER to the CLI's own permission flow"
      exit 0
      ;;
  esac
fi

# Timeout - fail closed (deny)
debug_log "TIMEOUT after ${ELAPSED}0ms, denying"
echo "Permission check timed out" >&2
rm -f "$REQ_FILE" 2>/dev/null
exit 2
