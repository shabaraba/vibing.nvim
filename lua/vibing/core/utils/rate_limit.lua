--- Rate limit detection and normalization
---
--- The Claude CLI reports usage limits through three independent channels, none of which is
--- officially documented (see anthropics/claude-code#24596). This module normalizes all of them
--- into a single shape so callers never depend on a particular payload spelling:
---
---   1. `rate_limit_event` on the stream-json stdout — the only channel that carries the reset
---      timestamp, so it is the primary source.
---   2. The `StopFailure` hook with `error_type = "rate_limit"` — fires when the turn actually
---      died, but carries no reset time.
---   3. The error text of a failed run — last-resort fallback if both of the above change shape.
---
--- @module vibing.core.utils.rate_limit

local M = {}

--- Statuses that mean the request was actually rejected, as opposed to a remaining-quota warning
--- emitted mid-turn. Anything not listed here is treated as informational.
local REJECTED_STATUSES = {
  rejected = true,
  blocked = true,
  exceeded = true,
}

--- Substrings that identify a usage/rate limit in a free-form error message. Matched
--- case-insensitively against the whole error text.
local ERROR_TEXT_PATTERNS = {
  "usage limit",
  "rate limit",
  "rate_limit",
  "too many requests",
}

--- @class Vibing.RateLimitInfo
--- @field rejected boolean Whether the request was actually turned away
--- @field resets_at number|nil Unix timestamp in seconds
--- @field limit_type string|nil e.g. "five_hour", "weekly"
--- @field status string|nil Raw status string, kept for diagnostics
--- @field source string Which channel detected it ("stream_event"|"hook"|"error_text")
--- @field raw table|nil Original payload, kept for debug logging

--- Coerce a timestamp to Unix seconds.
--- The CLI emits seconds today, but a millisecond value would be silently ~50000x too far in the
--- future and schedule a resume that never fires, so normalize instead of trusting the unit.
--- @param value any
--- @return number|nil
local function to_unix_seconds(value)
  local n = tonumber(value)
  if not n or n <= 0 then
    return nil
  end
  -- Any plausible "seconds" value is < 1e12 until the year 33658; anything above is milliseconds.
  if n > 1e12 then
    n = n / 1000
  end
  return math.floor(n)
end

--- Read the first present key from a table, accepting both camelCase and snake_case spellings.
--- @param tbl table
--- @param ... string
--- @return any
local function pick(tbl, ...)
  for _, key in ipairs({ ... }) do
    if tbl[key] ~= nil then
      return tbl[key]
    end
  end
  return nil
end

--- Normalize a raw `rate_limit_event` payload.
--- Every field is optional: an unrecognized payload still yields a usable (if reset-less) result
--- rather than an error, so a schema change degrades the feature instead of breaking the stream.
--- @param msg table Decoded `rate_limit_event` JSON line
--- @return Vibing.RateLimitInfo|nil
function M.from_event(msg)
  if type(msg) ~= "table" then
    return nil
  end

  local info = pick(msg, "rate_limit_info", "rateLimitInfo")
  if type(info) ~= "table" then
    -- Some builds may inline the fields on the event itself.
    info = msg
  end

  local status = pick(info, "status", "rateLimitStatus")
  local overage_status = pick(info, "overageStatus", "overage_status")

  return {
    rejected = REJECTED_STATUSES[tostring(status):lower()] == true
      or REJECTED_STATUSES[tostring(overage_status):lower()] == true,
    resets_at = to_unix_seconds(pick(info, "resetsAt", "resets_at", "resetAt", "reset_at")),
    limit_type = pick(info, "rateLimitType", "rate_limit_type", "limitType"),
    status = status and tostring(status) or nil,
    source = "stream_event",
    raw = info,
  }
end

--- Build info from a `StopFailure` hook payload.
--- The hook fires only when the turn actually died, so a `rate_limit` error_type is authoritative
--- about rejection — but it carries no reset timestamp.
--- @param hook_input table Decoded hook stdin JSON
--- @return Vibing.RateLimitInfo|nil
function M.from_hook(hook_input)
  if type(hook_input) ~= "table" then
    return nil
  end

  local error_type = pick(hook_input, "error_type", "errorType")
  if tostring(error_type):lower() ~= "rate_limit" then
    return nil
  end

  return {
    rejected = true,
    resets_at = to_unix_seconds(pick(hook_input, "resets_at", "resetsAt", "retry_after_epoch")),
    limit_type = pick(hook_input, "rate_limit_type", "rateLimitType"),
    status = "rate_limit",
    source = "hook",
    raw = hook_input,
  }
end

--- Last-resort detection from a free-form error string.
--- @param text string|nil
--- @return Vibing.RateLimitInfo|nil
function M.from_error_text(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end

  local lower = text:lower()
  for _, pattern in ipairs(ERROR_TEXT_PATTERNS) do
    if lower:find(pattern, 1, true) then
      return {
        rejected = true,
        resets_at = nil,
        limit_type = nil,
        status = "error_text",
        source = "error_text",
        raw = nil,
      }
    end
  end
  return nil
end

--- Merge detections from several channels into the single best answer.
--- Rejection is a logical OR (any channel claiming rejection wins), while `resets_at` takes the
--- first channel that actually supplies one — in practice always the stream event.
---
--- Iterates by argument count rather than with ipairs: callers routinely pass nil for channels
--- that reported nothing (a turn with no rate_limit_event is the common case), and ipairs stops
--- at the first nil hole — which silently discarded every later channel, including a
--- hook-only detection.
--- @param ... Vibing.RateLimitInfo|nil
--- @return Vibing.RateLimitInfo|nil
function M.merge(...)
  local args = { ... }
  local merged = nil
  for i = 1, select("#", ...) do
    local info = args[i]
    if info then
      if not merged then
        merged = vim.deepcopy(info)
      else
        merged.rejected = merged.rejected or info.rejected
        merged.resets_at = merged.resets_at or info.resets_at
        merged.limit_type = merged.limit_type or info.limit_type
        if info.source and not merged.source:find(info.source, 1, true) then
          merged.source = merged.source .. "+" .. info.source
        end
      end
    end
  end
  return merged
end

--- Human-readable description for notifications.
--- @param info Vibing.RateLimitInfo
--- @return string
function M.describe(info)
  local parts = {}
  table.insert(parts, info.limit_type and ("limit=" .. tostring(info.limit_type)) or "limit=unknown")
  if info.resets_at then
    table.insert(parts, "resets at " .. os.date("%Y-%m-%d %H:%M:%S", info.resets_at))
  else
    table.insert(parts, "reset time unknown")
  end
  table.insert(parts, "via " .. info.source)
  return table.concat(parts, ", ")
end

return M
