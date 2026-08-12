#!/bin/bash
# vibing.nvim StopFailure hook
#
# Fires when a turn ends because of an API error. Unlike pre-tool-use.sh this hook has no
# decision power at all — Claude Code ignores its exit code and output — so it is pure
# fire-and-forget: drop the payload where Neovim can read it, poke the RPC server, and get out
# of the way without waiting for a response.
#
# Always exits 0. A failure here must never look like a tool denial.

debug_log() {
  [ -n "$VIBING_DEBUG" ] && echo "$(date) [stop-failure] $1" >> "/tmp/vibing-hook-debug.log"
}

INPUT=$(cat)
PORT="${VIBING_NVIM_RPC_PORT}"

debug_log "fired, PID=$$, PORT=${PORT:-UNSET}"

# No RPC port = not running inside vibing.nvim, nothing to report to.
if [ -z "$PORT" ]; then
  exit 0
fi

REQUEST_ID="$(date +%s)-$$-$RANDOM"
COMM_DIR="${VIBING_HOOK_COMM_DIR:-/tmp/vibing-hook-${PORT}}"
mkdir -p "$COMM_DIR" 2>/dev/null

REQ_FILE="$COMM_DIR/${REQUEST_ID}.fail"

# Write payload file (atomic via rename) so the RPC server never reads a partial JSON document.
printf '%s' "$INPUT" > "${REQ_FILE}.tmp"
mv "${REQ_FILE}.tmp" "$REQ_FILE"

# Identifies which chat buffer's stream this failure belongs to (see ActiveStreamRegistry).
# Restricted to [A-Za-z0-9_] since it's interpolated directly into the JSON request below.
HANDLE_ID="${VIBING_HANDLE_ID//[^A-Za-z0-9_]/}"

printf '{"method":"stop_failure","id":1,"params":{"request_id":"%s","handle_id":"%s"}}\n' "$REQUEST_ID" "$HANDLE_ID" \
  | nc -w 1 127.0.0.1 "$PORT" >/dev/null 2>&1
debug_log "notified nvim (status=$?), request_id=$REQUEST_ID"

exit 0
