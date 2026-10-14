---@diagnostic disable: undefined-field
local Decoder = require("vibing.infrastructure.adapter.decoders.copilot_json")

describe("decoders.copilot_json", function()
  local function decode(state, msg)
    return Decoder.decode(msg, state)
  end

  describe("extract_result_text", function()
    it("reads a string result", function()
      assert.are.equal("done", Decoder.extract_result_text({ result = "done" }))
    end)

    it("reads result.content", function()
      assert.are.equal("hello\n", Decoder.extract_result_text({ result = { content = "hello\n" } }))
    end)

    it("reads the error field when there is no result", function()
      assert.are.equal("boom", Decoder.extract_result_text({ error = "boom" }))
    end)

    it("unwraps a table error into its message", function()
      local text = Decoder.extract_result_text({
        success = false,
        error = { message = "Permission to run this tool was denied", code = "denied" },
      })
      assert.are.equal("Permission to run this tool was denied", text)
    end)

    it("encodes a table error that has no message", function()
      local text = Decoder.extract_result_text({ error = { code = "denied" } })
      assert.is_true(text:find("denied", 1, true) ~= nil)
      assert.is_nil(text:find("table: 0x", 1, true))
    end)

    it("returns an empty string with no usable field", function()
      assert.are.equal("", Decoder.extract_result_text({}))
    end)
  end)

  it("pairs start and complete by toolCallId, in copilot's own tool names", function()
    local state = {}
    local start = decode(state, {
      type = "tool.execution_start",
      data = { toolCallId = "t1", toolName = "bash", arguments = { command = "ls" } },
    })
    assert.same({ { kind = "tool_start", id = "t1", name = "bash", input = { command = "ls" } } }, start)
    local finish = decode(state, {
      type = "tool.execution_complete",
      data = { toolCallId = "t1", success = false, error = { message = "denied" } },
    })
    assert.same({ { kind = "tool_end", id = "t1", result = "denied", is_error = true } }, finish)
  end)

  it("decodes arguments sent as a JSON string", function()
    local events = decode({}, {
      type = "tool.execution_start",
      data = { toolCallId = "t1", toolName = "bash", arguments = '{"command":"ls"}' },
    })
    assert.same({ command = "ls" }, events[1].input)
  end)

  it("gives an anonymous call an id so its result still pairs up", function()
    local state = {}
    local start = decode(state, { type = "tool.execution_start", data = { toolName = "bash", arguments = {} } })
    local finish = decode(state, { type = "tool.execution_complete", data = { success = true, result = "ok" } })
    assert.is_string(start[1].id)
    assert.equals(start[1].id, finish[1].id)
  end)

  it("falls back to the whole message only when no delta was streamed for it", function()
    local state = {}
    decode(state, { type = "assistant.message_delta", data = { messageId = "m1", deltaContent = "hi" } })
    assert.same({}, decode(state, { type = "assistant.message", data = { messageId = "m1", content = "hi" } }))
    assert.same(
      { { kind = "text", delta = "solo" } },
      decode(state, { type = "assistant.message", data = { messageId = "m2", content = "solo" } })
    )
  end)

  it("names the session from the result event", function()
    assert.same({ { kind = "session", session_id = "s1" } }, decode({}, { type = "result", sessionId = "s1" }))
  end)

  it("unwraps a table error message", function()
    local events = decode({}, { type = "error", data = { message = { message = "quota", code = "429" } } })
    assert.same({ { kind = "error", message = "quota" } }, events)
  end)
end)
