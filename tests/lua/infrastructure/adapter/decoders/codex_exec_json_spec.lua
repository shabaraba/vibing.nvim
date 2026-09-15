---@diagnostic disable: undefined-field
local Decoder = require("vibing.infrastructure.adapter.decoders.codex_exec_json")

describe("decoders.codex_exec_json", function()
  local function decode(state, msg)
    return Decoder.decode(msg, state)
  end

  it("names the session from thread.started and proves the CLI alive", function()
    local events = decode({}, { type = "thread.started", thread_id = "th-1" })
    assert.same({ { kind = "session", session_id = "th-1" }, { kind = "first_response" } }, events)
  end)

  it("unwraps the shell wrapper from a command_execution", function()
    local events = decode({}, {
      type = "item.started",
      item = { id = "i1", type = "command_execution", command = "/bin/bash -lc 'ls -la'" },
    })
    assert.same({ { kind = "tool_start", id = "i1", name = "Bash", input = { command = "ls -la" } } }, events)
  end)

  it("emits a file_change as apply_patch with every path, in codex's own name", function()
    -- The vocabulary maps apply_patch to Edit; the decoder does not, so the renderer and the
    -- permission handler translate through the same table.
    local state = {}
    decode(state, {
      type = "item.started",
      item = { id = "i2", type = "file_change", changes = { { path = "a.lua", kind = "update" }, { path = "b.lua", kind = "add" } } },
    })
    local events = decode(state, {
      type = "item.completed",
      item = { id = "i2", type = "file_change", changes = { { path = "a.lua", kind = "update" }, { path = "b.lua", kind = "add" } } },
    })
    assert.same({ { kind = "tool_end", id = "i2", result = "modified a.lua\ncreated b.lua" } }, events)
  end)

  it("synthesises the start for an item that only ever completes", function()
    local events = decode({}, {
      type = "item.completed",
      item = { id = "i3", type = "web_search", query = "vibing" },
    })
    assert.equals("tool_start", events[1].kind)
    assert.equals("web_search", events[1].name)
    assert.equals("vibing", events[1].input.query)
    assert.equals("tool_end", events[2].kind)
  end)

  it("names an MCP call the way claude's stream would", function()
    local events = decode({}, {
      type = "item.completed",
      item = { id = "i4", type = "mcp_tool_call", server = "vibing_nvim", tool = "nvim_list_windows", result = { content = { { text = "ok" } } } },
    })
    assert.equals("mcp__vibing_nvim__nvim_list_windows", events[1].name)
    assert.same({ kind = "tool_end", id = "i4", result = "ok" }, events[2])
  end)

  it("marks an MCP error as such", function()
    local events = decode({}, {
      type = "item.completed",
      item = { id = "i5", type = "mcp_tool_call", server = "s", tool = "t", error = "boom" },
    })
    assert.is_true(events[2].is_error)
    assert.equals("boom", events[2].result)
  end)

  it("streams agent text and reasoning", function()
    assert.same({ { kind = "text", delta = "hi" } }, decode({}, { type = "item.completed", item = { type = "agent_message", text = "hi" } }))
    assert.same({ { kind = "thinking", delta = "hm" } }, decode({}, { type = "item.completed", item = { type = "reasoning", text = "hm" } }))
  end)

  it("tags turn.completed usage as a whole-turn accumulator", function()
    local events = decode({}, { type = "turn.completed", usage = { input_tokens = 10, output_tokens = 2 } })
    assert.equals("usage", events[1].kind)
    assert.equals("codex", events[1].accumulator.backend)
    assert.equals(10, events[1].accumulator.totals.input)
  end)

  it("reports failures from both channels as non-fatal errors", function()
    assert.same({ { kind = "error", message = "x" } }, decode({}, { type = "error", message = "x" }))
    assert.same({ { kind = "error", message = "y" } }, decode({}, { type = "turn.failed", error = { message = "y" } }))
    assert.same({ { kind = "error", message = "z" } }, decode({}, { type = "turn.failed", error = "z" }))
  end)
end)
