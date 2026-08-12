--- Parse a user-supplied time spec into a Unix timestamp
---
--- Used by `:VibingSchedule <when>`. Kept free of Neovim and clock state (`now` is injected) so
--- the rollover and range rules are testable without waiting on the wall clock.
---
--- @module vibing.core.utils.when

local M = {}

--- Relative offsets, longest pattern first: "1h30m" must not be consumed by the bare-hours rule.
local OFFSET_RULES = {
  { pattern = "^(%d+)h(%d+)m$", seconds = function(h, m) return h * 3600 + m * 60 end },
  { pattern = "^(%d+)h$", seconds = function(h) return h * 3600 end },
  { pattern = "^(%d+)m$", seconds = function(m) return m * 60 end },
  { pattern = "^(%d+)s$", seconds = function(s) return s end },
}

--- @param spec string
--- @param now number
--- @return number|nil offset_seconds
local function parse_offset(spec, now)
  for _, rule in ipairs(OFFSET_RULES) do
    local a, b = spec:match(rule.pattern)
    if a then
      local offset = rule.seconds(tonumber(a), tonumber(b))
      if offset > 0 then
        return now + offset
      end
      return nil
    end
  end
  return nil
end

--- @param hour number
--- @param min number
--- @return boolean
local function valid_clock(hour, min)
  return hour >= 0 and hour <= 23 and min >= 0 and min <= 59
end

--- Parse a time spec.
--- Accepts `90s` / `30m` / `2h` / `1h30m` (relative), `18:30` (next occurrence of that clock
--- time), and `2026-08-14T07:05` or `2026-08-14 07:05` (absolute).
--- @param spec string
--- @param now number|nil Defaults to os.time(); injected by tests
--- @return number|nil unix_seconds, string|nil reason
function M.parse(spec, now)
  now = now or os.time()

  if type(spec) ~= "string" then
    return nil, "expected a string"
  end
  spec = vim.trim(spec)
  if spec == "" then
    return nil, "empty time spec"
  end

  local offset_at = parse_offset(spec, now)
  if offset_at then
    return offset_at
  end

  local year, month, day, hour, min = spec:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d)$")
  if year then
    hour, min = tonumber(hour), tonumber(min)
    if not valid_clock(hour, min) then
      return nil, "hour/minute out of range: " .. spec
    end
    return os.time({
      year = tonumber(year),
      month = tonumber(month),
      day = tonumber(day),
      hour = hour,
      min = min,
      sec = 0,
    })
  end

  hour, min = spec:match("^(%d%d?):(%d%d)$")
  if hour then
    hour, min = tonumber(hour), tonumber(min)
    if not valid_clock(hour, min) then
      return nil, "hour/minute out of range: " .. spec
    end
    local today = os.date("*t", now)
    local at = os.time({ year = today.year, month = today.month, day = today.day, hour = hour, min = min, sec = 0 })
    if at <= now then
      -- The clock time already passed today; the user means the next one.
      at = at + 24 * 60 * 60
    end
    return at
  end

  return nil, string.format("could not parse '%s' (try 30m, 2h, 1h30m, 18:30 or 2026-08-14T07:05)", spec)
end

return M
