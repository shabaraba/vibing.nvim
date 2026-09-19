---@diagnostic disable: undefined-field
local Decoder = require("vibing.infrastructure.adapter.decoders.claude_stream_json")

describe("decoders.claude_stream_json", function()
  local function decode(state, msg)
    return Decoder.decode(msg, state)
  end

  local function kinds(events)
    return vim.tbl_map(function(e)
      return e.kind
    end, events)
  end

  it("reports the session once, not on every line that carries it", function()
    local state = {}
    local first = decode(state, { type = "system", subtype = "init", session_id = "s1" })
    local second = decode(state, { type = "assistant", session_id = "s1", message = { content = {} } })
    assert.equals("session", first[1].kind)
    assert.is_false(vim.tbl_contains(kinds(second), "session"))
  end)

  it("carries init facts out as cli_info and proves the CLI alive", function()
    local events = decode({}, {
      type = "system",
      subtype = "init",
      claude_code_version = "2.1.231",
      model = "claude-opus-5",
      tools = { "Bash", "Read" },
      mcp_servers = { { name = "x" } },
    })
    assert.same({ kind = "cli_info", version = "2.1.231", model = "claude-opus-5", tools = 2, mcp_servers = 1 }, events[1])
    assert.equals("first_response", events[2].kind)
  end)

  it("streams text deltas and nothing else from stream_event", function()
    local events = decode({}, {
      type = "stream_event",
      event = { type = "content_block_delta", delta = { type = "text_delta", text = "hi" } },
    })
    assert.same({ { kind = "text", delta = "hi" } }, events)
    assert.same({}, decode({}, {
      type = "stream_event",
      event = { type = "content_block_delta", delta = { type = "thinking_delta", thinking = "private" } },
    }))
  end)

  it("turns an assistant message into usage plus tool starts", function()
    local events = decode({}, {
      type = "assistant",
      parent_tool_use_id = vim.NIL,
      message = {
        usage = { input_tokens = 1 },
        content = { { type = "tool_use", id = "t1", name = "Bash", input = { command = "ls" } } },
      },
    })
    assert.same({ "usage", "tool_start" }, kinds(events))
    assert.is_false(events[1].subagent)
    assert.equals("Bash", events[2].name)
  end)

  it("routes a subagent's message to subagent_text with its usage marked", function()
    local events = decode({}, {
      type = "assistant",
      parent_tool_use_id = "t1",
      message = { usage = { input_tokens = 1 }, content = { { type = "text", text = "found it" } } },
    })
    assert.same({ "usage", "subagent_text" }, kinds(events))
    assert.is_true(events[1].subagent)
    assert.same({ kind = "subagent_text", parent_id = "t1", text = "found it" }, events[2])
  end)

  it("treats an explicit null parent as the parent's own message", function()
    local events = decode({}, {
      type = "user",
      parent_tool_use_id = vim.NIL,
      message = { content = { { type = "tool_result", tool_use_id = "t1", content = { { type = "text", text = "ok" } } } } },
    })
    assert.same({ { kind = "tool_end", id = "t1", result = "ok" } }, events)
  end)

  it("drops a subagent's own user events", function()
    assert.same({}, decode({}, {
      type = "user",
      parent_tool_use_id = "t1",
      message = { content = { { type = "tool_result", tool_use_id = "nested", content = "x" } } },
    }))
  end)

  it("reports a failed result as a fatal error, ahead of the turn_end it also ends", function()
    -- Order matters: the resident transport completes the turn on `turn_end`, so a `result` that
    -- declared the turn failed has to have reached `resultErrors` before that happens.
    assert.same(
      { { kind = "error", message = "boom", fatal = true }, { kind = "turn_end", subtype = nil } },
      decode({}, { type = "result", is_error = true, result = "boom" })
    )
  end)

  it("ends the turn on a successful result too", function()
    -- The only event that says a turn is over. Under the oneshot transport the process exit says
    -- it instead, so a success used to produce no event at all -- which a resident process, which
    -- does not exit, would have read as a turn that never ended.
    assert.same({ { kind = "turn_end", subtype = "success" } }, decode({}, { type = "result", subtype = "success" }))
  end)

  it("normalises a rate_limit_event", function()
    local events = decode({}, { type = "rate_limit_event", rate_limit_info = { status = "rejected", resetsAt = 1700000000 } })
    assert.equals("rate_limit", events[1].kind)
    assert.is_true(events[1].info.rejected)
  end)
end)
