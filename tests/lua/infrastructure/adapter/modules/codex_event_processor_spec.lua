describe("adapter.modules.codex_event_processor", function()
  local Processor = require("vibing.infrastructure.adapter.modules.codex_event_processor")

  local LIMIT = "You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), "
    .. "visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 3:01 PM."

  local function new_context()
    return { output = {}, errorOutput = {} }
  end

  local function process(context, event)
    Processor.processLine(vim.json.encode(event), context)
  end

  describe("failure reporting", function()
    it("records a rejected turn once, not once per event", function()
      -- codex announces the same failure on both `error` and `turn.failed`, and errorOutput is
      -- concatenated with no separator, so keeping both rendered one run-on sentence in the chat.
      local context = new_context()

      process(context, { type = "error", message = LIMIT })
      process(context, { type = "turn.failed", error = { message = LIMIT } })

      assert.same({ LIMIT }, context.errorOutput)
    end)

    it("keeps two different failures", function()
      local context = new_context()

      process(context, { type = "error", message = "stream disconnected before completion" })
      process(context, { type = "turn.failed", error = { message = LIMIT } })

      assert.equals(2, #context.errorOutput)
    end)

    it("keeps a repeat that is not immediately adjacent", function()
      local context = new_context()

      process(context, { type = "error", message = LIMIT })
      process(context, { type = "error", message = "sandbox denied exec" })
      process(context, { type = "turn.failed", error = { message = LIMIT } })

      assert.same({ LIMIT, "sandbox denied exec", LIMIT }, context.errorOutput)
    end)

    it("accepts a turn.failed whose error is a bare string", function()
      local context = new_context()

      process(context, { type = "turn.failed", error = "exceeded retry limit" })

      assert.same({ "exceeded retry limit" }, context.errorOutput)
    end)
  end)
end)
