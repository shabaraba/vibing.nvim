---@diagnostic disable: undefined-field
--- The third measured gate: may a CLI's own approval request be held open for a human? (#861)
---
--- Parallel to `transports.can_wait_for_approval`, and the
--- parallel is the point — a backend gets the behaviour only when a measurement covers the budget
--- the current configuration derives. What differs is which measurement. These specs pin that the
--- measurements cannot be substituted for each other, and that raising the configured wait past the
--- evidence turns the feature **off** rather than waiting past it.
local WaitBudget = require("vibing.infrastructure.hooks.wait_budget")
local Config = require("vibing.config")

describe("the native-approval wait gate", function()
  local original

  before_each(function()
    original = vim.deepcopy(Config.get() or {})
  end)

  after_each(function()
    Config.setup(original)
  end)

  local function with_wait(seconds)
    Config.setup(vim.tbl_deep_extend("force", vim.deepcopy(original), { permissions = { approval_wait_sec = seconds } }))
  end

  it("refuses an unmeasured backend, which is the safe default to forget", function()
    assert.is_false(WaitBudget.can_wait_for_native_approval(nil))
    assert.is_false(WaitBudget.can_wait_for_native_approval({}))
    assert.is_false(WaitBudget.can_wait_for_native_approval({ measured_wait_floor_sec = "960" }))
  end)

  it("opens when the floor covers the whole budget, and not one second before", function()
    with_wait(900)
    local budget = WaitBudget.native_approval_budget_sec()

    assert.is_true(WaitBudget.can_wait_for_native_approval({ measured_wait_floor_sec = budget }))
    assert.is_false(WaitBudget.can_wait_for_native_approval({ measured_wait_floor_sec = budget - 1 }))
  end)

  it("shuts again when the user asks to wait longer than anyone measured", function()
    -- The way to wait longer is to re-run the perf cell at the longer value, not to raise the
    -- number and hope.
    with_wait(900)
    assert.is_true(WaitBudget.can_wait_for_native_approval({ measured_wait_floor_sec = 960 }))

    with_wait(1200)
    assert.is_false(WaitBudget.can_wait_for_native_approval({ measured_wait_floor_sec = 960 }))
  end)

  it("carries the answer home with a margin, for the native transport", function()
    with_wait(900)
    assert.equals(
      WaitBudget.approval_wait_sec() + WaitBudget.NATIVE_APPROVAL_MARGIN_SEC,
      WaitBudget.native_approval_budget_sec()
    )
    assert.is_true(WaitBudget.native_approval_budget_sec() > WaitBudget.approval_wait_sec())
  end)

  it("refuses a measurement for the retired MCP question channel", function()
    assert.is_false(WaitBudget.can_wait_for_native_approval({ measured_answer_wait_sec = 960 }))
  end)

  describe("the codex descriptor", function()
    it("records the floor the perf cell actually measured", function()
      -- `tests/perf/codex_approval_answer_after_delay.sh 960` passed with its control; this is the
      -- number that cell produced, and the gate below is what it buys.
      local codex = require("vibing.infrastructure.adapter.backends.codex")

      assert.equals(960, codex.native_approval.measured_wait_floor_sec)
      with_wait(900)
      assert.is_true(WaitBudget.can_wait_for_native_approval(codex.native_approval))
    end)
  end)
end)
