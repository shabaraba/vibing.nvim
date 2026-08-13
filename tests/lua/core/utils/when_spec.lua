describe("when.parse", function()
  local When = require("vibing.core.utils.when")

  -- 2026-08-12 10:00:00 local time. Fixed so HH:MM cases are not wall-clock dependent.
  local NOW = os.time({ year = 2026, month = 8, day = 12, hour = 10, min = 0, sec = 0 })

  it("parses a seconds offset", function()
    assert.equals(NOW + 1, When.parse("1s", NOW))
  end)

  it("parses a minutes offset", function()
    assert.equals(NOW + 30 * 60, When.parse("30m", NOW))
  end)

  it("parses an hours offset", function()
    assert.equals(NOW + 2 * 3600, When.parse("2h", NOW))
  end)

  it("parses a combined hours+minutes offset", function()
    assert.equals(NOW + 90 * 60, When.parse("1h30m", NOW))
  end)

  it("parses a clock time later today", function()
    assert.equals(os.time({ year = 2026, month = 8, day = 12, hour = 18, min = 30, sec = 0 }), When.parse("18:30", NOW))
  end)

  it("rolls a clock time that already passed to the next day", function()
    assert.equals(os.time({ year = 2026, month = 8, day = 13, hour = 9, min = 0, sec = 0 }), When.parse("09:00", NOW))
  end)

  it("rolls a past clock time across a month boundary", function()
    local last_day = os.time({ year = 2026, month = 8, day = 31, hour = 10, min = 0, sec = 0 })
    assert.equals(os.time({ year = 2026, month = 9, day = 1, hour = 9, min = 0, sec = 0 }), When.parse("09:00", last_day))
  end)

  it("parses an absolute date-time", function()
    local expected = os.time({ year = 2026, month = 8, day = 14, hour = 7, min = 5, sec = 0 })
    assert.equals(expected, When.parse("2026-08-14T07:05", NOW))
  end)

  it("accepts a space instead of T in an absolute date-time", function()
    local expected = os.time({ year = 2026, month = 8, day = 14, hour = 7, min = 5, sec = 0 })
    assert.equals(expected, When.parse("2026-08-14 07:05", NOW))
  end)

  it("rejects an unparseable spec with a reason", function()
    local at, reason = When.parse("tomorrow-ish", NOW)
    assert.is_nil(at)
    assert.is_string(reason)
  end)

  it("rejects an out-of-range clock time", function()
    assert.is_nil(When.parse("25:00", NOW))
  end)

  it("rejects an empty spec", function()
    assert.is_nil(When.parse("", NOW))
  end)

  it("rejects a zero offset", function()
    -- A zero delay is almost certainly a typo, and firing instantly defeats the point.
    assert.is_nil(When.parse("0m", NOW))
  end)
end)
