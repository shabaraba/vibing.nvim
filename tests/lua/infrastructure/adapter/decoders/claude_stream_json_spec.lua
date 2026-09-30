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

  it("carries the same prompt_uuid on a fatal error as on the turn_end it precedes", function()
    -- Both are cut from the same `result`, so `event_renderer.handlers.error` can tell a foreign
    -- turn's failure apart from this one's the same way `duplex_turn.ends_this_turn` does for the
    -- `turn_end` -- otherwise an unrelated background turn's failure would land in `resultErrors`
    -- and a turn that actually succeeded would complete reporting an error nobody saw.
    assert.same({
      { kind = "error", message = "boom", fatal = true, prompt_uuid = "vibing-abc" },
      { kind = "turn_end", subtype = nil, prompt_uuid = "vibing-abc" },
    }, decode({}, { type = "result", is_error = true, result = "boom", user_message_uuid = "vibing-abc" }))
  end)

  it("ends the turn on a successful result too", function()
    -- The only event that says a turn is over. Under the oneshot transport the process exit says
    -- it instead, so a success used to produce no event at all -- which a resident process, which
    -- does not exit, would have read as a turn that never ended.
    assert.same({ { kind = "turn_end", subtype = "success" } }, decode({}, { type = "result", subtype = "success" }))
  end)

  it("carries out which prompt a result answers", function()
    -- The CLI echoes the input envelope's `uuid` back here, and that is the only thing separating
    -- this turn's result from one the CLI ran for itself.
    assert.same(
      { { kind = "turn_end", subtype = "success", prompt_uuid = "vibing-abc" } },
      decode({}, { type = "result", subtype = "success", user_message_uuid = "vibing-abc" })
    )
  end)

  it("carries no prompt out of a result the CLI produced for itself", function()
    -- Measured: a turn started by a `task_notification` omits the field entirely, and a JSON null
    -- would arrive as `vim.NIL` -- truthy in Lua, and a uuid nothing could ever match.
    assert.same(
      { { kind = "turn_end", subtype = "success" } },
      decode({}, { type = "result", subtype = "success", user_message_uuid = vim.NIL })
    )
  end)

  it("reports the CLI naming a prompt back", function()
    assert.same(
      { { kind = "prompt_ack", prompt_uuid = "vibing-abc", state = "queued" } },
      decode({}, { type = "command_lifecycle", command_uuid = "vibing-abc", state = "queued" })
    )
  end)

  it("ignores a lifecycle line that names no prompt", function()
    assert.same({}, decode({}, { type = "command_lifecycle", state = "queued" }))
  end)

  it("survives the string-content user events /compact replays", function()
    -- Captured from claude 2.1.x: after `compact_boundary` the CLI replays the summary it has just
    -- written and a `<local-command-stdout>` line, both as `user` events whose `content` is a plain
    -- string rather than a block list. `ipairs` on that raised, and on the resident transport the
    -- raise escaped the stdout callback -- taking the `result` line sharing that batch with it, so
    -- the turn never ended and the chat sat at `responding` for good.
    assert.same({}, decode({}, { type = "user", message = { role = "user", content = "This session is being continued…" } }))
    assert.same(
      {},
      decode({}, {
        type = "user",
        message = { role = "user", content = "<local-command-stdout>Compacted </local-command-stdout>" },
      })
    )
    assert.same({}, decode({}, { type = "assistant", message = { role = "assistant", content = "plain prose" } }))
  end)

  it("normalises a rate_limit_event", function()
    local events = decode({}, { type = "rate_limit_event", rate_limit_info = { status = "rejected", resetsAt = 1700000000 } })
    assert.equals("rate_limit", events[1].kind)
    assert.is_true(events[1].info.rejected)
  end)

  describe("background subagents", function()
    it("tracks a backgrounded task_started", function()
      local events = decode({}, {
        type = "system",
        subtype = "task_started",
        task_id = "a5a51adc038e56bf6",
        tool_use_id = "toolu_01HQ",
        description = "Reply PONG",
        subagent_type = "general-purpose",
        is_backgrounded = true,
      })
      -- Only what something downstream reads: the id the ledger and the transcript path are keyed
      -- by, and the brief the completion line names the task with.
      assert.same({ kind = "background_task_started", task_id = "a5a51adc038e56bf6", description = "Reply PONG" }, events[1])
    end)

    -- A foreground subagent closes inside the turn that launched it, as a tool_result. Tracking it
    -- would put it in the unreported set forever, since no task_notification ever names it.
    it("ignores a foreground task_started", function()
      local events = decode({}, {
        type = "system",
        subtype = "task_started",
        task_id = "a1",
        is_backgrounded = false,
      })
      assert.is_false(vim.tbl_contains(kinds(events), "background_task_started"))
    end)

    it("carries a task_notification out as a completion with its usage", function()
      local events = decode({}, {
        type = "system",
        subtype = "task_notification",
        task_id = "a5a51adc038e56bf6",
        tool_use_id = "toolu_01HQ",
        status = "completed",
        summary = "PONG",
        output_file = "/tmp/x/tasks/a5a51adc038e56bf6.output",
        usage = { total_tokens = 19469, duration_ms = 1610 },
      })
      assert.same({
        kind = "background_task_done",
        task_id = "a5a51adc038e56bf6",
        status = "completed",
        usage = { total_tokens = 19469, duration_ms = 1610 },
      }, events[1])
    end)
  end)
end)
