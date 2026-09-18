--- The two predicates behind `wait_for_completed_turn` (#781 review).
---
--- They are unit-tested rather than exercised through a real turn because the thing being pinned is
--- exactly the case a real turn does not produce on demand: a turn that *failed*. An E2E run can
--- only show the green path, which is what let the weakness stand — `wait_for_assistant_turns` was
--- documented as aborting on a failed turn and never could, because `send_message` writes the
--- header when the response starts and appends `**Error:**` under it later.
local helper = require("vibing.testing.e2e_helper")

local HEADER = "\n## Assistant <!-- 2026-09-18 11:22:35 -->\n"
local UNSENT = "\n## User <!-- unsent -->\n"

--- @param bodies string[] one entry per assistant turn
--- @param trailing string? what follows the last turn
local function chat(bodies, trailing)
  local text = "## User <!-- 2026-09-18 11:22:30 -->\nhello\n"
  for _, body in ipairs(bodies) do
    text = text .. HEADER .. body
  end
  return text .. (trailing or "")
end

describe("e2e_helper turn predicates", function()
  -- The slice boundary neither predicate below can see: both stay green when it starts or ends one
  -- byte off. Comparing the whole slice is the only assertion that moves when the walk does.
  describe("_assistant_section", function()
    it("starts immediately after its header and stops at the next one", function()
      local text = chat({ "one\n", "two\n" }, UNSENT)
      assert.equals("\none\n", helper._assistant_section(text, 1))
      assert.equals("\ntwo\n" .. UNSENT, helper._assistant_section(text, 2))
    end)

    it("has nothing to slice for a turn that has not started", function()
      assert.is_nil(helper._assistant_section(chat({ "one\n" }, UNSENT), 2))
    end)
  end)

  describe("_turn_failure", function()
    it("says nothing about a turn that answered", function()
      assert.is_nil(helper._turn_failure(chat({ "one\n" }, UNSENT), 1))
    end)

    it("reports the error the turn itself wrote", function()
      local text = chat({ "\n\n**Error:** stream closed unexpectedly\n" }, UNSENT)
      assert.equals("**Error:** stream closed unexpectedly", helper._turn_failure(text, 1))
    end)

    -- The reason the check is scoped to one section instead of scanning the buffer. A failed turn
    -- stays in the transcript, so a global scan condemns every turn that runs after it.
    it("does not blame a later turn for an earlier turn's error", function()
      local text = chat({ "\n\n**Error:** stream closed unexpectedly\n", "two\n" }, UNSENT)
      assert.is_nil(helper._turn_failure(text, 2))
      assert.equals("**Error:** stream closed unexpectedly", helper._turn_failure(text, 1))
    end)

    it("has no opinion on a turn that has not started", function()
      assert.is_nil(helper._turn_failure(chat({ "one\n" }, UNSENT), 2))
    end)
  end)

  describe("_turn_completed", function()
    -- The whole point. The header is written when the response starts, so counting headers reports
    -- a turn still in flight as finished.
    it("is false while the turn is still streaming", function()
      assert.is_false(helper._turn_completed(chat({ "on" }), 1))
    end)

    it("is true once the unsent section follows the turn", function()
      assert.is_true(helper._turn_completed(chat({ "one\n" }, UNSENT), 1))
    end)

    it("is false when the only unsent section precedes the turn asked about", function()
      -- Turn 1 finished and turn 2 is mid-stream: the buffer holds an unsent marker, but it is
      -- turn 1's. Scanning the whole buffer would call turn 2 complete.
      local text = "## User <!-- 2026-09-18 11:22:30 -->\nhello\n"
        .. HEADER
        .. "one\n"
        .. UNSENT
        .. HEADER
        .. "tw"
      assert.is_true(helper._turn_completed(text, 1))
      assert.is_false(helper._turn_completed(text, 2))
    end)

    it("is false when the turn has not started", function()
      assert.is_false(helper._turn_completed(chat({ "one\n" }, UNSENT), 2))
    end)
  end)
end)
