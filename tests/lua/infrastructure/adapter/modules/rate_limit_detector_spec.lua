describe("adapter.modules.rate_limit_detector", function()
  local Detector = require("vibing.infrastructure.adapter.modules.rate_limit_detector")
  local Handler = require("vibing.infrastructure.rpc.handlers.rate_limit")

  local real_take_failure

  before_each(function()
    real_take_failure = Handler.take_failure
  end)

  after_each(function()
    Handler.take_failure = real_take_failure
  end)

  --- Make the StopFailure handler hand back `info` exactly once, the way the real `take_failure`
  --- consumes what the hook parked.
  --- @param info table|nil
  --- @return table calls Every handle_id the detector asked about
  local function stub_hook(info)
    local calls = {}
    Handler.take_failure = function(handle_id)
      table.insert(calls, handle_id)
      local taken = info
      info = nil
      return taken
    end
    return calls
  end

  it("attaches nothing when no channel reports a limit", function()
    stub_hook(nil)
    local response = { content = "done" }
    Detector.attach(response, "handle-1", {})
    assert.is_nil(response._rate_limit_info)
  end)

  it("attaches nothing when the turn failed for an unrelated reason", function()
    stub_hook(nil)
    local response = { error = "ENOENT: no such file or directory" }
    Detector.attach(response, "handle-1", {})
    assert.is_nil(response._rate_limit_info)
  end)

  it("detects a limit from the error text alone", function()
    -- The only channel codex, copilot and grok have.
    stub_hook(nil)
    local response = { error = "You've hit your usage limit. Try again later." }
    Detector.attach(response, "handle-1", {})
    assert.is_not_nil(response._rate_limit_info)
    assert.is_true(response._rate_limit_info.rejected)
    assert.is_nil(response._rate_limit_info.resets_at)
  end)

  it("carries the stream event's reset time through to the response", function()
    stub_hook(nil)
    local resets_at = os.time() + 3600
    local response = { error = "Claude AI usage limit reached" }
    Detector.attach(response, "handle-1", {
      rateLimitInfo = { rejected = true, resets_at = resets_at, source = "stream_event" },
    })
    assert.equals(resets_at, response._rate_limit_info.resets_at)
  end)

  it("ignores a stream event that only reports remaining quota", function()
    -- `status = "allowed"` arrives mid-turn on healthy runs; treating it as a rejection would
    -- park a chat that had just answered fine.
    stub_hook(nil)
    local response = { content = "done" }
    Detector.attach(response, "handle-1", {
      rateLimitInfo = { rejected = false, resets_at = os.time() + 60, source = "stream_event" },
    })
    assert.is_nil(response._rate_limit_info)
  end)

  it("claims the failure the StopFailure hook parked for this handle", function()
    local calls = stub_hook({ rejected = true, limit_type = "weekly", source = "hook" })
    local response = { error = "Process exited with code 1" }
    Detector.attach(response, "handle-abc", {})
    assert.same({ "handle-abc" }, calls)
    assert.equals("weekly", response._rate_limit_info.limit_type)
  end)

  it("tolerates an adapter with no event context", function()
    stub_hook(nil)
    local response = { error = "rate limit exceeded" }
    Detector.attach(response, "handle-1", nil)
    assert.is_not_nil(response._rate_limit_info)
  end)
end)
