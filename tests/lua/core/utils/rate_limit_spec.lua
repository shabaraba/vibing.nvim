describe("rate_limit", function()
  local RateLimit = require("vibing.core.utils.rate_limit")

  describe("from_event", function()
    it("extracts reset time, type and rejection from a rejected event", function()
      local info = RateLimit.from_event({
        type = "rate_limit_event",
        rate_limit_info = {
          status = "rejected",
          resetsAt = 1778193600,
          rateLimitType = "five_hour",
        },
      })

      assert.is_true(info.rejected)
      assert.equals(1778193600, info.resets_at)
      assert.equals("five_hour", info.limit_type)
      assert.equals("stream_event", info.source)
    end)

    it("treats a non-rejected status as informational", function()
      local info = RateLimit.from_event({
        rate_limit_info = { status = "allowed", resetsAt = 1778193600 },
      })

      assert.is_false(info.rejected)
      -- Reset time is still surfaced so a later rejection can reuse it.
      assert.equals(1778193600, info.resets_at)
    end)

    it("accepts snake_case field spellings", function()
      local info = RateLimit.from_event({
        rate_limit_info = { status = "blocked", resets_at = 1778193600, rate_limit_type = "weekly" },
      })

      assert.is_true(info.rejected)
      assert.equals(1778193600, info.resets_at)
      assert.equals("weekly", info.limit_type)
    end)

    it("normalizes a millisecond timestamp to seconds", function()
      local info = RateLimit.from_event({
        rate_limit_info = { status = "rejected", resetsAt = 1778193600000 },
      })

      assert.equals(1778193600, info.resets_at)
    end)

    -- Real payload from an account with no extra-usage credits. Every event looks like this,
    -- including the ones for turns that completed normally.
    it("ignores overageStatus, which reports billing availability rather than this request", function()
      local info = RateLimit.from_event({
        rate_limit_info = {
          status = "allowed",
          resetsAt = 1786506000,
          rateLimitType = "five_hour",
          overageStatus = "rejected",
          overageDisabledReason = "out_of_credits",
          isUsingOverage = false,
        },
      })

      assert.is_false(info.rejected)
      assert.equals(1786506000, info.resets_at)
      assert.equals("five_hour", info.limit_type)
    end)

    it("survives an unrecognized payload instead of erroring", function()
      local info = RateLimit.from_event({ type = "rate_limit_event" })

      assert.is_not_nil(info)
      assert.is_false(info.rejected)
      assert.is_nil(info.resets_at)
    end)

    it("returns nil for a non-table payload", function()
      assert.is_nil(RateLimit.from_event(nil))
      assert.is_nil(RateLimit.from_event("rate_limit_event"))
    end)
  end)

  describe("from_hook", function()
    it("accepts a rate_limit error type", function()
      local info = RateLimit.from_hook({ hook_event_name = "StopFailure", error_type = "rate_limit" })

      assert.is_true(info.rejected)
      assert.equals("hook", info.source)
    end)

    it("ignores other API error types", function()
      assert.is_nil(RateLimit.from_hook({ error_type = "overloaded" }))
      assert.is_nil(RateLimit.from_hook({ error_type = "billing_error" }))
      assert.is_nil(RateLimit.from_hook({}))
    end)
  end)

  describe("from_error_text", function()
    it("detects limit wording case-insensitively", function()
      assert.is_not_nil(RateLimit.from_error_text("Claude AI usage limit reached"))
      assert.is_not_nil(RateLimit.from_error_text("429 Too Many Requests"))
    end)

    it("ignores unrelated errors", function()
      assert.is_nil(RateLimit.from_error_text("ENOENT: no such file"))
      assert.is_nil(RateLimit.from_error_text(""))
      assert.is_nil(RateLimit.from_error_text(nil))
    end)
  end)

  describe("merge", function()
    it("keeps the reset time from the stream event when the hook has none", function()
      local merged = RateLimit.merge(
        RateLimit.from_event({ rate_limit_info = { status = "rejected", resetsAt = 1778193600 } }),
        RateLimit.from_hook({ error_type = "rate_limit" })
      )

      assert.is_true(merged.rejected)
      assert.equals(1778193600, merged.resets_at)
    end)

    it("promotes rejection when only one channel saw it", function()
      local merged = RateLimit.merge(
        RateLimit.from_event({ rate_limit_info = { status = "allowed", resetsAt = 1778193600 } }),
        RateLimit.from_hook({ error_type = "rate_limit" })
      )

      assert.is_true(merged.rejected)
      assert.equals(1778193600, merged.resets_at)
    end)

    it("returns nil when nothing was detected", function()
      assert.is_nil(RateLimit.merge(nil, nil, nil))
    end)

    -- Regression: merge iterated with ipairs, which stops at the first nil hole. Production
    -- always passes one argument per channel, so a nil in any position silently discarded every
    -- later channel — including a hook-only detection, the whole point of the StopFailure hook.
    it("detects a hook-only limit when the leading channel is nil (regression)", function()
      local merged = RateLimit.merge(nil, RateLimit.from_hook({ error_type = "rate_limit" }), nil)

      assert.is_not_nil(merged)
      assert.is_true(merged.rejected)
    end)

    it("still reaches the error-text fallback past a nil middle channel (regression)", function()
      local merged = RateLimit.merge(
        RateLimit.from_event({ rate_limit_info = { status = "allowed", resetsAt = 1778193600 } }),
        nil,
        RateLimit.from_error_text("Claude AI usage limit reached")
      )

      assert.is_true(merged.rejected)
      assert.equals(1778193600, merged.resets_at)
    end)

    it("detects a limit reported only by the last channel (regression)", function()
      local merged = RateLimit.merge(nil, nil, RateLimit.from_error_text("429 Too Many Requests"))

      assert.is_not_nil(merged)
      assert.is_true(merged.rejected)
    end)
  end)
end)
