#!/bin/bash
# vibing.nvim pre-tool-use hook
# Communicates with Neovim RPC server to check tool permissions
#
# Usage: pre-tool-use.sh [claude|copilot]
#
# The RPC protocol is identical for every backend; only the way a decision is handed back to the
# CLI differs, hence the argument. Claude (and the CLIs that copy its hook schema) read a nested
# {"hookSpecificOutput":{...}} object and take the deny reason from stderr. Copilot reads a FLAT
# {"permissionDecision":...} object and ignores both the wrapper and stderr -- verified against
# copilot 1.0.78, where a nested deny ran the tool anyway and an exit 2 reported only "hook exited
# with code 2" to the model.
FORMAT="${1:-claude}"

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

# Identifies the CLI process this hook invocation belongs to. An environment variable is fixed when
# the child is spawned, so this can only ever name a process; which *turn* is in flight on it is
# resolved in Neovim by rpc/hook_scope.lua, and that is what keeps concurrent chats from
# cross-wiring each other's approval UI.
# Restricted to [A-Za-z0-9_] since it's interpolated directly into the JSON request below. The same
# character class is asserted against lua/vibing/core/utils/identity.lua by its spec, so a rename
# on either side fails the build instead of silently losing attribution.
PROCESS_ID="${VIBING_PROCESS_ID//[^A-Za-z0-9_]/}"

# Notify Neovim RPC server (fire-and-forget)
printf '{"method":"check_tool_permission","id":1,"params":{"request_id":"%s","process_id":"%s"}}\n' "$REQUEST_ID" "$PROCESS_ID" \
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

# Poll for the response file, in 0.1s ticks.
#
# How long this may block is one of three deadlines that must stay in this order:
#
#   permissions.approval_wait_sec  <  this  <  the backend's configured hook timeout
#
# Every CLI measured ignores a hook that outlives its own configured timeout and runs the tool
# anyway -- fail open -- where this script's own expiry exits 2 and fails closed. So this must give
# up strictly first, and vibing.nvim's own approval limit must give up before that. All three come
# from one number (lua/vibing/infrastructure/hooks/wait_budget.lua), handed here in the environment
# because this file is fixed on disk and shared by every chat.
#
# Without the variable we do not know which of the three numbers the CLI was configured with, so
# the fallback is not the default derivation -- it is deliberately *below the smallest timeout
# vibing.nvim will ever register*, which is what keeps the ordering true even for a user who lowered
# approval_wait_sec. A hook reaching this without the variable is already off the normal path (a
# stale generated settings file, a CLI that dropped the environment); the variable travels with the
# RPC port, and without a port this script has already exited above. Its spec pins the fallback
# against that smallest timeout, and pins the multiplier below against the sleep.
MAX_WAIT_SEC="${VIBING_HOOK_MAX_WAIT_SEC:-60}"
case "$MAX_WAIT_SEC" in
  '' | *[!0-9]*) MAX_WAIT_SEC=60 ;;
esac
ELAPSED=0
MAX_WAIT=$((MAX_WAIT_SEC * 10))
while [ ! -f "$RES_FILE" ] && [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  sleep 0.1
  ELAPSED=$((ELAPSED + 1))
done

if [ -f "$RES_FILE" ]; then
  RESPONSE=$(cat "$RES_FILE")
  debug_log "got response: $RESPONSE"
  rm -f "$REQ_FILE" "$RES_FILE" 2>/dev/null

  DECISION=$(echo "$RESPONSE" | grep -o '"permissionDecision":"[^"]*"' | head -1 | cut -d'"' -f4)

  # Copilot's flat form. Produced by unwrapping the response rather than re-encoding the fields,
  # so a reason containing quotes or backslashes stays escaped exactly as vim.json.encode wrote
  # it -- rebuilding the JSON from grep/cut output would emit an unparsable object for those, and
  # a hook whose output does not parse is read as "no decision", i.e. the tool runs.
  flat_decision() {
    local body="${RESPONSE#\{\"hookSpecificOutput\":}"
    # Returns non-zero when the wrapper was not there to strip, i.e. the response has a shape this
    # script does not recognise. Callers must not print a half-unwrapped object: copilot reads
    # output it cannot parse as "no decision", which under --allow-all-tools runs the tool.
    [ "$body" = "$RESPONSE" ] && return 1
    printf '%s' "${body%\}}"
  }

  case "$DECISION" in
    deny)
      REASON=$(echo "$RESPONSE" | grep -o '"permissionDecisionReason":"[^"]*"' | head -1 | cut -d'"' -f4)
      debug_log "DENY: $REASON"
      if [ "$FORMAT" = "copilot" ]; then
        # Exit 0, not 2: both deny, but exit 2 replaces the reason with a generic message, and the
        # reason is the only way a deny rule's `message` reaches the model. Every *failure* path
        # below still exits non-zero, which copilot also fails closed on.
        if flat_decision; then
          exit 0
        fi
        # Unrecognised response shape. Fall through to the exit-2 deny: it loses the reason, but
        # it still denies, where printing an object copilot cannot parse would let the tool run.
      fi
      echo "${REASON:-Denied by vibing.nvim}" >&2
      exit 2
      ;;
    allow)
      # An explicit grant, which makes the CLI skip its own permission gate. Exiting 0 without
      # printing this is NOT a grant -- a silent exit 0 reads as "no opinion", and in headless
      # `-p` mode the gate it falls back to cannot prompt anyone, so the tool is refused (#564).
      debug_log "ALLOW (explicit grant)"
      if [ "$FORMAT" = "copilot" ]; then
        # An unwrap failure falls through to the nested form below, which copilot ignores — and
        # since copilot runs with --allow-all-tools, no opinion still means the tool runs.
        flat_decision && exit 0
      fi
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
