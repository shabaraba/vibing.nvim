---@diagnostic disable: undefined-field
local Decoder = require("vibing.infrastructure.adapter.decoders.pi_json")

--- Decode one record against a fresh state, unless a state is supplied.
--- @param msg table
--- @param state table?
--- @return Vibing.CanonicalEvent[]
local function decode(msg, state)
  return Decoder.decode(msg, state or {})
end

--- @param events Vibing.CanonicalEvent[]
--- @param kind string
--- @return Vibing.CanonicalEvent|nil
local function first_of(events, kind)
  for _, event in ipairs(events) do
    if event.kind == kind then
      return event
    end
  end
  return nil
end

describe("decoders.pi_json", function()
  describe("the terminal event", function()
    it("ends the turn on agent_settled", function()
      assert.same({ { kind = "turn_end" } }, decode({ type = "agent_settled" }))
    end)

    it("does NOT end the turn on pi's own turn_end", function()
      -- Measured against Pi 0.87.1: a request that calls a tool emits `turn_start`/`turn_end` twice,
      -- once per model turn. Mapping Pi's `turn_end` onto the canonical one declares the request
      -- finished while the tool result is still being answered -- and on a resident transport that
      -- hands the second half of the answer to whatever turn comes next.
      local events = decode({ type = "turn_end", message = { role = "assistant", content = {} } })
      assert.is_nil(first_of(events, "turn_end"))
    end)
  end)

  describe("session", function()
    it("reports the id from the session record", function()
      assert.same(
        { { kind = "session", session_id = "01a0cc07" } },
        decode({ type = "session", version = 3, id = "01a0cc07" })
      )
    end)

    it("says nothing when the record carries no id", function()
      assert.same({}, decode({ type = "session", version = 3 }))
    end)
  end)

  describe("first_response", function()
    it("is announced once per stream, not once per model turn", function()
      -- It cancels the resume watchdog; a request with a tool call passes turn_start twice.
      local state = {}
      assert.is_not_nil(first_of(decode({ type = "agent_start" }, state), "first_response"))
      assert.is_nil(first_of(decode({ type = "turn_start" }, state), "first_response"))
    end)

    it("is announced by turn_start when that is what arrives first", function()
      -- `--mode rpc` emits no `session` record and the driver may join mid-stream.
      assert.is_not_nil(first_of(decode({ type = "turn_start" }), "first_response"))
    end)
  end)

  describe("assistant content", function()
    it("streams text deltas", function()
      local events = decode({
        type = "message_update",
        assistantMessageEvent = { type = "text_delta", contentIndex = 1, delta = "PONG" },
      })
      assert.same({ { kind = "text", delta = "PONG" } }, events)
    end)

    it("streams thinking deltas", function()
      local events = decode({
        type = "message_update",
        assistantMessageEvent = { type = "thinking_delta", contentIndex = 0, delta = "hmm" },
      })
      assert.same({ { kind = "thinking", delta = "hmm" } }, events)
    end)

    it("ignores the settled text_end, which would double the message", function()
      -- `text_end` carries the whole content, not a delta; emitting it after the deltas would
      -- render every assistant message twice.
      local events = decode({
        type = "message_update",
        assistantMessageEvent = { type = "text_end", contentIndex = 1, content = "PONG" },
      })
      assert.same({}, events)
    end)

    it("reports a provider stream error without marking it fatal", function()
      -- Pi may still settle the agent afterwards. `fatal` puts it in `resultErrors`, which reports
      -- a recovered turn as a failed one.
      local events = decode({
        type = "message_update",
        assistantMessageEvent = { type = "error", reason = "overloaded", error = "429 from provider" },
      })
      assert.equals("429 from provider", events[1].message)
      assert.equals("error", events[1].kind)
      assert.is_nil(events[1].fatal)
    end)

    it("unwraps an error object instead of rendering `table: 0x...` into the chat", function()
      -- The payload is undocumented and has been seen both ways. Every field of a rate-limit or
      -- error signal has to be optional, and a shape change must degrade the message rather than
      -- turn a provider fault into something that reads as a vibing.nvim bug.
      local events = decode({
        type = "message_update",
        assistantMessageEvent = { type = "error", error = { message = "context length exceeded" } },
      })
      assert.equals("context length exceeded", events[1].message)
    end)

    it("falls back to `reason`, then to a fixed message, rather than to nil", function()
      local only_reason = decode({
        type = "message_update",
        assistantMessageEvent = { type = "error", reason = "overloaded" },
      })
      assert.equals("overloaded", only_reason[1].message)

      local neither = decode({ type = "message_update", assistantMessageEvent = { type = "error" } })
      assert.is_truthy(neither[1].message:find("Pi", 1, true))
    end)
  end)

  describe("usage", function()
    it("records the settled per-message figure from an assistant message_end", function()
      local events = decode({
        type = "message_end",
        message = {
          role = "assistant",
          usage = { input = 905, output = 51, cacheRead = 12, cacheWrite = 3, totalTokens = 956 },
        },
      })
      assert.same({
        {
          kind = "usage",
          record = { input_tokens = 905, cache_read_input_tokens = 12, cache_creation_input_tokens = 3 },
        },
      }, events)
    end)

    it("ignores the usage riding on every message_update", function()
      -- It is repeated on each delta and grows within a message; recording those multiplies the
      -- turn's token count by the number of deltas.
      local events = decode({
        type = "message_update",
        usage = { input = 905, output = 51 },
        assistantMessageEvent = { type = "text_delta", delta = "x" },
      })
      assert.is_nil(first_of(events, "usage"))
    end)

    it("ignores a non-assistant message_end", function()
      assert.same({}, decode({ type = "message_end", message = { role = "toolResult" } }))
    end)
  end)

  describe("cli_info", function()
    it("announces the model actually serving the request, once", function()
      -- Pi resolves the model through its own models.json, so the chat can be answered by something
      -- other than what `model:` frontmatter says.
      local state = {}
      local events = decode({
        type = "message_start",
        message = { role = "assistant", model = "mlx-community/Qwen3.6-27B-4bit" },
      }, state)
      assert.equals("mlx-community/Qwen3.6-27B-4bit", first_of(events, "cli_info").model)

      local again = decode({ type = "message_start", message = { role = "assistant", model = "other" } }, state)
      assert.is_nil(first_of(again, "cli_info"))
    end)

    it("says nothing for the system and user messages pi echoes back", function()
      assert.same({}, decode({ type = "message_start", message = { role = "system", content = "" } }))
    end)
  end)

  describe("tool calls", function()
    it("starts a tool in pi's own vocabulary, for the renderer to canonicalise", function()
      assert.same({
        { kind = "tool_start", id = "t1", name = "bash", input = { command = "ls" } },
      }, decode({ type = "tool_execution_start", toolCallId = "t1", toolName = "bash", args = { command = "ls" } }))
    end)

    it("flattens pi's MCP-style content blocks into result text", function()
      local events = decode({
        type = "tool_execution_end",
        toolCallId = "t1",
        isError = false,
        result = { content = { { type = "text", text = "a.txt\n" }, { type = "text", text = "b.txt\n" } } },
      })
      assert.same({ { kind = "tool_end", id = "t1", result = "a.txt\nb.txt\n", is_error = false } }, events)
    end)

    it("carries the error flag through", function()
      local events = decode({
        type = "tool_execution_end",
        toolCallId = "t1",
        isError = true,
        result = { content = { { type = "text", text = "no such file" } } },
      })
      assert.is_true(events[1].is_error)
    end)

    it("drops an event with no toolCallId rather than opening a tool nothing can close", function()
      -- `context._tools` is keyed by id; an entry with a nil key would never be cleared and the
      -- stream-fixture contract ("a tool that starts also ends") could not hold.
      assert.same({}, decode({ type = "tool_execution_start", toolName = "bash", args = {} }))
      assert.same({}, decode({ type = "tool_execution_end", result = {} }))
    end)

    it("ignores tool_execution_update, whose partial output the renderer has no slot for", function()
      assert.same({}, decode({ type = "tool_execution_update", toolCallId = "t1", partialResult = "a" }))
    end)
  end)

  it("ignores a record type it does not know, including rpc command responses", function()
    -- `--mode rpc` interleaves `{"type":"response",...}` with the session events.
    assert.same({}, decode({ type = "response", command = "prompt", success = true }))
    assert.same({}, decode({ type = "agent_end", messages = {} }))
  end)
end)
