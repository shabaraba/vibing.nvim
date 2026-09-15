-- One real grok turn, end to end through the shared adapter.
--
-- Deliberately not the tool-rendering assertion its codex and copilot siblings make: grok's
-- headless stream carries no tool event at all (`decoders/grok_streaming_json.lua`, and the
-- capture in `tests/fixtures/streams/grok/` is a turn that did call a tool and still emitted only
-- thought/text/end). There is no `⏺` to wait for, and asserting its absence would fail the day
-- grok starts reporting tool calls -- which is a change to notice, not a regression to guard.
--
-- What this does cover is the P0 behaviour change: grok's `on_chunk` now carries the handle id
-- like the other backends, and grok registers the session it resumes. A turn that reaches the
-- chat at all is that plumbing working.
local helper = require("vibing.testing.e2e_helper")

if not helper.should_run() then
  return
end

local TIMEOUTS = {
  BUFFER_READY = 5000,
  -- What every other real-turn spec in this directory budgets. A green run returns as soon as the
  -- pattern matches, so this only decides how long a turn that hangs rather than erroring costs.
  ASSISTANT_RESPONSE = 60000,
}

describe("E2E: grok completes a turn through the shared adapter", function()
  local nvim_instance

  before_each(function()
    nvim_instance = helper.spawn_backend_instance("grok")
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("answers, and the turn is not an error", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")

    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "chat buffer should be created")

    helper.send_keys(nvim_instance, "G")
    helper.send_keys(nvim_instance, "i")
    helper.send_keys(nvim_instance, 'Say "test"')
    helper.send_keys(nvim_instance, "<Esc>")
    helper.send_keys(nvim_instance, "<CR>")

    local reason
    ok, reason = helper.wait_for_assistant_turns(nvim_instance, 1, TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, reason or "grok should answer without the turn failing")
  end)
end)
