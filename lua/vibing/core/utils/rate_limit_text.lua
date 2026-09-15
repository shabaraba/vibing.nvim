--- Read a reset time out of a CLI's prose usage-limit message
---
--- Codex is why this exists. It has no rate-limit stream event and no `StopFailure` hook, so its
--- error text is the only channel it has — and that text does state when the limit lifts:
--- `protocol/src/num_format.rs` appends `" or try again at "` followed by `%-I:%M %p` when the
--- reset falls on the same day, or `%b %-d, %Y %-I:%M %p` when it does not. Without reading it
--- `resets_at` stays nil, and everything downstream that needs a moment degrades — no
--- `.vibing/limit-state.json`, so sibling chats keep sending into a limit still in force, and the
--- rejected turn resumes on a fixed fallback delay instead of at the reset.
---
--- This is a parse, not a guess. Nothing is inferred when the text does not state a time: the
--- `" or try again later."` wording the same formatter emits when it has no timestamp, and any
--- phrasing not recognised here, both yield nil and leave the caller exactly as it was.
---
--- @module vibing.core.utils.rate_limit_text

local M = {}

--- `%b` is chrono's English abbreviation whatever the user's locale is, and the key is the first
--- three letters so a spelled-out month parses too.
local MONTHS = {
  jan = 1,
  feb = 2,
  mar = 3,
  apr = 4,
  may = 5,
  jun = 6,
  jul = 7,
  aug = 8,
  sep = 9,
  oct = 10,
  nov = 11,
  dec = 12,
}

--- A time further out than this was misread rather than reported: the longest window any of these
--- plans advertises is weekly. Matches the sanity ceiling `auto_resume.lua` applies to the value
--- it is eventually handed, so an implausible parse is dropped here instead of warning there.
local MAX_AHEAD_SEC = 8 * 24 * 60 * 60

--- The moment a stated clock time resolves to: the **end** of the minute it names.
---
--- The formatter truncates (`%-I:%M`), so "3:13 AM" names `[3:13:00, 3:13:59]` and says only that
--- the reset falls inside it. Every parse goes through here so that no later format can reintroduce
--- the start of the minute by writing `sec = 0` — which is the bug, and it fails silently.
--- `handbook/features/usage-limits.md` → "Reading the Reset Time Out of the Message".
--- @param parts table Fields for os.time, without `sec`
--- @return number|nil unix_seconds
local function stated_minute(parts)
  parts.sec = 59
  return os.time(parts)
end

--- Read a clock time anchored at the start of `s`.
--- Both the 12-hour form codex prints and a bare 24-hour one are accepted; `s` is already
--- lowercased by the caller, so the meridiem is matched in that case only.
--- @param s string
--- @return number|nil hour, number|nil min
local function parse_clock(s)
  local hour, min, meridiem = s:match("^(%d%d?):(%d%d)%s*([ap]m)")
  if hour then
    hour, min = tonumber(hour), tonumber(min)
    if hour < 1 or hour > 12 or min > 59 then
      return nil
    end
    return meridiem == "am" and hour % 12 or (hour % 12 + 12), min
  end

  hour, min = s:match("^(%d%d?):(%d%d)")
  if not hour then
    return nil
  end
  hour, min = tonumber(hour), tonumber(min)
  if hour > 23 or min > 59 then
    return nil
  end
  return hour, min
end

--- `%b %-d, %Y %-I:%M %p` — what codex prints when the reset is not today.
--- The day is allowed a trailing ordinal ("15th"), which the same binary ships a formatter for.
--- A date with no year is deliberately *not* accepted: inferring one is the kind of guess this
--- module exists to avoid, and falling through to nil costs only the feature's old behaviour.
--- @param rest string
--- @return number|nil unix_seconds
local function parse_dated(rest)
  local month, day, year, tail = rest:match("^(%a+)%s+(%d%d?)%a*,%s*(%d%d%d%d)%s+(.+)$")
  if not month then
    return nil
  end

  local month_num = MONTHS[month:sub(1, 3)]
  if not month_num then
    return nil
  end

  local hour, min = parse_clock(tail)
  if not hour then
    return nil
  end

  year, day = tonumber(year), tonumber(day)
  local at = stated_minute({ year = year, month = month_num, day = day, hour = hour, min = min })
  if not at then
    return nil
  end

  -- `os.time` normalizes rather than rejects, so "Sep 31" comes back as October 1 — a moment the
  -- message never stated. Only the calendar date is compared back: a local time inside a DST gap
  -- is legitimately shifted by an hour, and refusing that would drop a reset the CLI did state.
  local normalized = os.date("*t", at)
  if normalized.year ~= year or normalized.month ~= month_num or normalized.day ~= day then
    return nil
  end

  return at
end

--- A bare clock time, which the formatter uses only for a reset later the same day.
--- Deliberately never rolled forward to tomorrow: the CLI picks this form precisely because the
--- reset is today, so a time that reads as already past means the limit has just lifted. Both
--- readers of `resets_at` already handle a past moment — `limit_state.get_active` reports the
--- record inactive, and `auto_resume.compute_delay` resumes promptly — whereas adding a day would
--- park the chat for another 24 hours on nothing but a clock skew.
--- @param rest string
--- @param now number
--- @return number|nil unix_seconds
local function parse_time_of_day(rest, now)
  local hour, min = parse_clock(rest)
  if not hour then
    return nil
  end

  local today = os.date("*t", now)
  return stated_minute({ year = today.year, month = today.month, day = today.day, hour = hour, min = min })
end

--- The moment a usage-limit message says the limit lifts, or nil if it does not say.
--- @param text string|nil The CLI's error text
--- @param now number|nil Defaults to os.time(); injected by tests
--- @return number|nil unix_seconds
function M.parse_reset_at(text, now)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  now = now or os.time()

  -- Lowercased once, so every pattern below is written in one case. The tail is greedy on purpose:
  -- a message can carry trailing prose (or, as codex does on a failed turn, a second copy of
  -- itself), and every pattern is anchored at the start of what follows the phrase.
  local rest = text:lower():match("try again at%s+(.+)")
  if not rest then
    return nil
  end

  local at = parse_dated(rest) or parse_time_of_day(rest, now)
  if not at or at > now + MAX_AHEAD_SEC then
    return nil
  end
  return at
end

return M
