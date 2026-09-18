--- RPC handler for the StopFailure hook
---
--- Receives the "this turn died from an API error" signal that the CLI cannot express on its
--- stdout stream. The hook has no decision power, so this handler writes no response file and
--- the hook process never waits for one — it only parks the parsed result until the adapter's
--- on_done runs and merges it with what the stream reported (see claude_cli.lua).
---
--- @module vibing.infrastructure.rpc.handlers.rate_limit

local RateLimit = require("vibing.core.utils.rate_limit")

local M = {}

--- Parsed failures awaiting pickup by wrapped_on_done, keyed by **turn id**.
--- Keyed rather than a single slot so concurrent chats can't consume each other's failure — the
--- same class of bug ActiveStreamRegistry exists to prevent.
---
--- The hook names a process (`VIBING_PROCESS_ID`); the turn is resolved on arrival through
--- `rpc/hook_scope.lua`, because `wrapped_on_done` is what collects this and it knows the turn it is
--- completing. A failure whose turn is not named outright is dropped — see `M.stop_failure` for why
--- this handler refuses the guess its sibling accepts. The adapter always exports
--- `VIBING_PROCESS_ID`, so an unresolvable one is a real defect if it ever happens — and the
--- stream-json `rate_limit_event`, not this hook, is the primary detection channel anyway.
--- @type table<string, Vibing.RateLimitInfo>
local pending_failures = {}

--- Get the communication directory for the current RPC port
--- @return string
local function get_comm_dir()
  return require("vibing.infrastructure.rpc.comm_dir").path()
end

--- Handle a stop_failure notification from bin/hooks/stop-failure.sh
--- @param params {request_id: string, process_id: string?}
--- @return table RPC response (consumed by nobody; the hook does not wait for it)
function M.stop_failure(params)
  if not params or not params.request_id then
    return { status = "error", reason = "Missing request_id" }
  end

  -- This handler does not take the sole-active guess, unlike the permission one. Attributing a
  -- rate limit to the wrong chat does not merely answer one question wrongly: it writes a
  -- project-wide `limit-state.json` for that backend and hands the message to auto-resume, which
  -- spends tokens on a chat that was never rate-limited. Dropping is the recoverable answer.
  local scope = require("vibing.infrastructure.rpc.hook_scope").of(params)
  local turn_id = not scope.guessed and scope.turn_id or nil

  local req_file = get_comm_dir() .. "/" .. params.request_id .. ".fail"
  local f = io.open(req_file, "r")
  if not f then
    return { status = "ignored", reason = "payload file not found" }
  end
  local content = f:read("*a")
  f:close()
  os.remove(req_file)

  local ok, hook_input = pcall(vim.json.decode, content)
  if not ok or type(hook_input) ~= "table" then
    return { status = "ignored", reason = "invalid payload JSON" }
  end

  local info = RateLimit.from_hook(hook_input)
  if not info then
    -- Some other API error (overloaded, billing, ...). Not something auto-resume can act on.
    return { status = "ignored", reason = "not a rate limit" }
  end

  if not turn_id then
    vim.notify(
      "[vibing] StopFailure hook reported a rate limit it could not attribute to a turn; "
        .. "ignoring it rather than risk resuming the wrong chat",
      vim.log.levels.WARN
    )
    return { status = "ignored", reason = "unattributable turn" }
  end

  pending_failures[turn_id] = info
  return { status = "ok" }
end

--- Consume the recorded failure for a turn, if any.
--- Consuming (rather than peeking) guarantees a stale failure can't leak into the next turn of
--- the same chat and trigger a resume for a request that actually succeeded.
--- @param turn_id string|nil
--- @return Vibing.RateLimitInfo|nil
function M.take_failure(turn_id)
  if not turn_id then
    return nil
  end
  local info = pending_failures[turn_id]
  pending_failures[turn_id] = nil
  return info
end

--- Drop all recorded failures (test helper / session reset)
function M.reset()
  pending_failures = {}
end

return M
