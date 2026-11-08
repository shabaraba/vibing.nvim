local TurnUsage = require("vibing.infrastructure.adapter.modules.commandcode_turn_usage")

--- The three replies measured on 1.88.5: one request each, ~18.7k, with the totals running on.
local function reply(total, cached)
  return { inputTokens = total, cachedReadTokens = cached, cachedWriteTokens = 0, totalTokens = total + 4 }
end

describe("commandcode_turn_usage", function()
  describe("delta", function()
    it("takes the whole reply when the process has reported nothing yet", function()
      local delta, totals = TurnUsage.delta(nil, reply(18717, 6144))
      assert.equals(18717, delta.inputTokens)
      assert.equals(6144, delta.cachedReadTokens)
      assert.equals(18717, totals.inputTokens)
    end)

    it("subtracts what the previous reply on the same process had already counted", function()
      local _, first = TurnUsage.delta(nil, reply(18717, 6144))
      local delta = TurnUsage.delta(first, reply(37450, 24832))
      assert.equals(18733, delta.inputTokens)
      assert.equals(18688, delta.cachedReadTokens)
    end)

    it("treats a counter that went down as a restart and takes the whole reply", function()
      local _, before = TurnUsage.delta(nil, reply(931647, 931584))
      local delta = TurnUsage.delta(before, reply(18717, 6144))
      assert.equals(18717, delta.inputTokens)
      assert.equals(6144, delta.cachedReadTokens)
    end)

    it("reads missing or malformed fields as zero", function()
      local delta, totals = TurnUsage.delta(nil, { inputTokens = "n/a" })
      assert.equals(0, delta.inputTokens)
      assert.equals(0, totals.cachedReadTokens)
    end)
  end)

  describe("turn_record", function()
    local function context_of(record)
      return record.input_tokens + record.cache_read_input_tokens + record.cache_creation_input_tokens
    end

    it("makes the context exactly the window the CLI reported", function()
      local record = TurnUsage.turn_record(nil, reply(52558, 4608), 52600)
      assert.equals(52600, context_of(record))
      assert.equals(4608, record.cache_read_input_tokens)
    end)

    it("does not sum a later turn onto the earlier ones", function()
      local _, totals = TurnUsage.turn_record(nil, reply(18717, 6144), 18725)
      local record = TurnUsage.turn_record(totals, reply(37450, 24832), 18741)
      assert.equals(18741, context_of(record))
    end)

    it("clamps a cached read that exceeds the window, as a multi-request turn sums it", function()
      local record = TurnUsage.turn_record(nil, reply(300000, 250000), 90000)
      assert.equals(90000, context_of(record))
      assert.equals(90000, record.cache_read_input_tokens)
      assert.equals(0, record.input_tokens)
    end)

    it("clamps a cache write that exceeds what is left of the window", function()
      local usage = { inputTokens = 300000, cachedReadTokens = 0, cachedWriteTokens = 250000 }
      local record = TurnUsage.turn_record(nil, usage, 90000)
      assert.equals(90000, context_of(record))
      assert.equals(90000, record.cache_creation_input_tokens)
      assert.equals(0, record.input_tokens)
    end)

    it("falls back to the turn's own share when no window was reported", function()
      local _, totals = TurnUsage.turn_record(nil, reply(18717, 6144), nil)
      local record = TurnUsage.turn_record(totals, reply(37450, 24832), nil)
      assert.equals(18733, context_of(record))
      assert.equals(18688, record.cache_read_input_tokens)
      assert.equals(45, record.input_tokens)
    end)

    it("floors a fractional window and ignores one that is not finite", function()
      assert.equals(18725, context_of((TurnUsage.turn_record(nil, reply(18717, 6144), 18725.5))))
      assert.equals(18717, context_of((TurnUsage.turn_record(nil, reply(18717, 6144), math.huge))))
    end)

    it("ignores a window of zero rather than reporting an empty context", function()
      local record = TurnUsage.turn_record(nil, reply(18717, 6144), 0)
      assert.equals(18717, context_of(record))
    end)
  end)
end)
