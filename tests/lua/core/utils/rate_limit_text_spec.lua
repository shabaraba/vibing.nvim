describe("core.utils.rate_limit_text", function()
  local RateLimitText = require("vibing.core.utils.rate_limit_text")

  --- Every expectation is written against a fixed local wall-clock moment, so the assertions read
  --- as "14:29 today" rather than as an epoch number, and stay stable wherever the suite runs.
  local function at(hour, min, opts)
    opts = opts or {}
    return os.time({
      year = opts.year or 2026,
      month = opts.month or 9,
      day = opts.day or 14,
      hour = hour,
      min = min,
      sec = 0,
    })
  end

  local NOW = at(14, 29)

  --- The message codex 0.154 actually printed when the limit was hit, doubled the way the CLI
  --- emits it (`error` then `turn.failed`) so the greedy tail is exercised.
  local CODEX_MESSAGE = "You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), "
    .. "visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 3:01 PM."

  it("reads the same-day time codex prints", function()
    assert.equals(at(15, 1), RateLimitText.parse_reset_at(CODEX_MESSAGE, NOW))
  end)

  it("reads it out of a message repeated twice", function()
    assert.equals(at(15, 1), RateLimitText.parse_reset_at(CODEX_MESSAGE .. CODEX_MESSAGE, NOW))
  end)

  it("reads the dated form used when the reset is not today", function()
    local text = "You've hit your usage limit. Try again at Sep 15, 2026 3:01 AM"
    assert.equals(at(3, 1, { day = 15 }), RateLimitText.parse_reset_at(text, NOW))
  end)

  it("accepts an ordinal day and a spelled-out month", function()
    local text = "Try again at September 15th, 2026 11:45 PM"
    assert.equals(at(23, 45, { day = 15 }), RateLimitText.parse_reset_at(text, NOW))
  end)

  it("maps 12 AM to midnight and 12 PM to noon", function()
    assert.equals(at(0, 30, { day = 15 }), RateLimitText.parse_reset_at("try again at Sep 15, 2026 12:30 AM", NOW))
    assert.equals(at(12, 30), RateLimitText.parse_reset_at("try again at 12:30 PM", NOW))
  end)

  it("accepts a bare 24-hour clock", function()
    assert.equals(at(15, 1), RateLimitText.parse_reset_at("try again at 15:01", NOW))
  end)

  it("returns nil when the message states no time", function()
    assert.is_nil(RateLimitText.parse_reset_at("You've hit your usage limit. Try again later.", NOW))
  end)

  it("returns nil for a date with no year rather than inferring one", function()
    -- The year is what makes a dated form unambiguous; guessing it is exactly what this module
    -- refuses to do, and nil only costs the fixed-delay behaviour that predates the parse.
    assert.is_nil(RateLimitText.parse_reset_at("try again at Sep 15 3:01 PM", NOW))
  end)

  it("returns nil on an out-of-range clock", function()
    assert.is_nil(RateLimitText.parse_reset_at("try again at 13:75 PM", NOW))
    assert.is_nil(RateLimitText.parse_reset_at("try again at 25:00", NOW))
  end)

  it("rejects a time further out than any advertised window", function()
    assert.is_nil(RateLimitText.parse_reset_at("try again at Sep 15, 2027 3:01 PM", NOW))
  end)

  it("does not roll a past same-day time forward to tomorrow", function()
    -- The CLI uses the bare form only for a reset that is today, so a time reading as past means
    -- the limit has just lifted. Both readers of resets_at handle a past moment; adding a day
    -- would park the chat for 24 hours on clock skew alone.
    assert.equals(at(9, 5), RateLimitText.parse_reset_at("try again at 9:05 AM", NOW))
  end)

  it("returns nil for input that is not a usage-limit message", function()
    assert.is_nil(RateLimitText.parse_reset_at("ENOENT: no such file or directory", NOW))
    assert.is_nil(RateLimitText.parse_reset_at("", NOW))
    assert.is_nil(RateLimitText.parse_reset_at(nil, NOW))
  end)
end)
