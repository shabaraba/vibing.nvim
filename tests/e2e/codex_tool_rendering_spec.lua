-- ADR 009 C2 against the real codex CLI: a tool call is drawn in claude's shape.
--
-- This is the behaviour change P1 made deliberately -- codex used to draw `FileChange(2 files)`
-- and its own start-of-call header -- so it is also the one a future decoder edit can undo without
-- any unit test noticing. `conformance/renderer_parity_spec.lua` pins the rendering given canonical
-- events and `stream_fixtures_spec.lua` replays a capture through the decoder; neither can tell
-- that today's codex still emits the `item.*` shapes those were taken from. Only a real turn can.
--
-- One backend per file on purpose: `tests/e2e-timeout-gate.test.mjs` budgets a file's waits
-- against plenary's per-file job timeout, and a real turn is most of that budget.
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

describe("E2E: codex renders a tool call in claude's shape", function()
  local nvim_instance

  before_each(function()
    nvim_instance = helper.spawn_backend_instance("codex")
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("draws the tool header and result, not a backend-specific form", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")

    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "chat buffer should be created")

    local reason
    ok, reason = helper.expect_shared_tool_header(nvim_instance, TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, reason or "codex's tool call should be drawn with the shared tool header")
  end)
end)
