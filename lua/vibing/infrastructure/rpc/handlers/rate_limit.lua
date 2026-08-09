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

--- Parsed failures awaiting pickup by wrapped_on_done, keyed by handle_id.
--- Keyed rather than a single slot so concurrent chats can't consume each other's failure — the
--- same class of bug ActiveStreamRegistry exists to prevent.
--- @type table<string, Vibing.RateLimitInfo>
local pending_failures = {}

--- Failures that arrived without a usable handle_id. Keyed lookups can't reach these, so they are
--- consumed by whichever stream finishes first — only correct because a missing handle_id already
--- means we cannot tell the streams apart.
--- @type Vibing.RateLimitInfo|nil
local unkeyed_failure = nil

--- Get the communication directory for the current RPC port
--- @return string
local function get_comm_dir()
  local rpc_server = require("vibing.infrastructure.rpc.server")
  local port = rpc_server.get_port()
  return "/tmp/vibing-hook-" .. tostring(port or 0)
end

--- Handle a stop_failure notification from bin/hooks/stop-failure.sh
--- @param params {request_id: string, handle_id: string?}
--- @return table RPC response (consumed by nobody; the hook does not wait for it)
function M.stop_failure(params)
  if not params or not params.request_id then
    return { status = "error", reason = "Missing request_id" }
  end

  local handle_id = params.handle_id
  if handle_id == "" then
    handle_id = nil
  end

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

  if handle_id then
    pending_failures[handle_id] = info
  else
    unkeyed_failure = info
  end

  return { status = "ok" }
end

--- Consume the recorded failure for a handle, if any.
--- Consuming (rather than peeking) guarantees a stale failure can't leak into the next turn of
--- the same chat and trigger a resume for a request that actually succeeded.
--- @param handle_id string|nil
--- @return Vibing.RateLimitInfo|nil
function M.take_failure(handle_id)
  local info = handle_id and pending_failures[handle_id] or nil
  if info then
    pending_failures[handle_id] = nil
    return info
  end

  if unkeyed_failure then
    info = unkeyed_failure
    unkeyed_failure = nil
    return info
  end

  return nil
end

--- Drop all recorded failures (test helper / session reset)
function M.reset()
  pending_failures = {}
  unkeyed_failure = nil
end

return M
