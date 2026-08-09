describe("cli_event_processor rate_limit_event", function()
  local processor = require("vibing.infrastructure.adapter.modules.cli_event_processor")

  ---Feed a decoded event to the processor as it would arrive on stdout.
  ---@param context table
  ---@param rate_limit_info table
  local function feed(context, rate_limit_info)
    processor.processLine(vim.json.encode({ type = "rate_limit_event", rate_limit_info = rate_limit_info }), context)
  end

  it("records a rejection with its reset time", function()
    local context = {}
    feed(context, { status = "rejected", resetsAt = 1778193600, rateLimitType = "five_hour" })

    assert.is_true(context.rateLimitInfo.rejected)
    assert.equals(1778193600, context.rateLimitInfo.resets_at)
  end)

  it("keeps an earlier reset time when the rejection omits it (regression)", function()
    local context = {}
    -- Informational event carrying the reset timestamp...
    feed(context, { status = "allowed", resetsAt = 1778193600, rateLimitType = "five_hour" })
    -- ...followed by the rejection that ends the turn, without one.
    feed(context, { status = "rejected" })

    assert.is_true(context.rateLimitInfo.rejected)
    -- Losing this would silently downgrade the resume to fallback_delay_sec.
    assert.equals(1778193600, context.rateLimitInfo.resets_at)
    assert.equals("five_hour", context.rateLimitInfo.limit_type)
  end)

  it("prefers a newer reset time over an older one", function()
    local context = {}
    feed(context, { status = "allowed", resetsAt = 1778193600 })
    feed(context, { status = "rejected", resetsAt = 1778200000 })

    assert.equals(1778200000, context.rateLimitInfo.resets_at)
  end)

  it("does not let a trailing warning clear an earlier rejection", function()
    local context = {}
    feed(context, { status = "rejected", resetsAt = 1778193600 })
    feed(context, { status = "allowed" })

    assert.is_true(context.rateLimitInfo.rejected)
    assert.equals(1778193600, context.rateLimitInfo.resets_at)
  end)

  it("leaves the context untouched for unrelated events", function()
    local context = {}
    processor.processLine(vim.json.encode({ type = "result", subtype = "success" }), context)

    assert.is_nil(context.rateLimitInfo)
  end)
end)
