---@diagnostic disable: undefined-field
--- The third measured gate: may a CLI's own approval request be held open for a human? (#861)
---
--- Parallel to `can_answer_question_in_place` and to `transports.can_wait_for_approval`, and the
--- parallel is the point — a backend gets the behaviour only when a measurement covers the budget
--- the current configuration derives. What differs is which measurement. These specs pin that the
--- three cannot be substituted for each other, and that raising the configured wait past the
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

  it("carries the answer home with a margin, as the MCP route does", function()
    with_wait(900)
    assert.equals(
      WaitBudget.approval_wait_sec() + WaitBudget.NATIVE_APPROVAL_MARGIN_SEC,
      WaitBudget.native_approval_budget_sec()
    )
    assert.is_true(WaitBudget.native_approval_budget_sec() > WaitBudget.approval_wait_sec())
  end)

  it("is not the MCP gate wearing a different name", function()
    -- Borrowing one channel's measurement for another is the error both of the other two gates
    -- already warn about in prose; this is the assertion behind that prose.
    local floor = { measured_wait_floor_sec = WaitBudget.native_approval_budget_sec() }

    assert.is_true(WaitBudget.can_wait_for_native_approval(floor))
    assert.is_false(WaitBudget.can_answer_question_in_place(floor))
  end)

  it("sits under the ceiling on a server that answers nothing at all", function()
    with_wait(900)
    assert.is_true(WaitBudget.native_approval_budget_sec() < WaitBudget.MCP_TOOL_IDLE_TIMEOUT_SEC)
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
