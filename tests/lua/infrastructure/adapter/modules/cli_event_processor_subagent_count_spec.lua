-- Counting in-flight subagents (#701): a Task/Agent tool_use in the parent's own transcript
-- increments the owning stream's count in active_stream_registry.lua, and its tool_result
-- decrements it back -- so application/chat/concurrency.lua's at_capacity() can see the real
-- fan-out, not just the number of responding chats.

describe("cli_event_processor subagent counting", function()
  local processor = require("vibing.infrastructure.adapter.modules.cli_event_processor")

  ---Reload the registry for each test so counts from one test don't leak into the next.
  ---@return table
  local function fresh_registry()
    package.loaded["vibing.infrastructure.adapter.modules.active_stream_registry"] = nil
    package.loaded["vibing.infrastructure.adapter.modules.cli_event_processor"] = nil
    processor = require("vibing.infrastructure.adapter.modules.cli_event_processor")
    return require("vibing.infrastructure.adapter.modules.active_stream_registry")
  end

  ---@param handle_id string
  ---@return table context
  local function new_context(handle_id)
    return {
      handleId = handle_id,
      output = {},
      errorOutput = {},
      onChunk = function() end,
      _cached_display_mode = "full",
    }
  end

  local function feed(context, event)
    processor.processLine(vim.json.encode(event), context)
  end

  local function tool_use(id, name)
    return {
      type = "assistant",
      message = {
        role = "assistant",
        content = { { type = "tool_use", id = id, name = name, input = { subagent_type = "explorer" } } },
      },
    }
  end

  local function tool_result(id, content)
    return {
      type = "user",
      message = {
        role = "user",
        content = { { type = "tool_result", tool_use_id = id, content = content } },
      },
    }
  end

  it("increments the owning stream's count when a Task tool_use starts", function()
    local registry = fresh_registry()
    registry.register({ handle_id = "h1", adapter = {} })
    local context = new_context("h1")

    feed(context, tool_use("toolu_1", "Task"))

    assert.equals(1, registry.total_subagent_count())
  end)

  it("decrements it back once the tool_result lands", function()
    local registry = fresh_registry()
    registry.register({ handle_id = "h1", adapter = {} })
    local context = new_context("h1")

    feed(context, tool_use("toolu_1", "Agent"))
    feed(context, tool_result("toolu_1", "done"))

    assert.equals(0, registry.total_subagent_count())
  end)

  it("counts several concurrent subagents from the same chat", function()
    local registry = fresh_registry()
    registry.register({ handle_id = "h1", adapter = {} })
    local context = new_context("h1")

    feed(context, tool_use("toolu_1", "Task"))
    feed(context, tool_use("toolu_2", "Task"))
    feed(context, tool_use("toolu_3", "Task"))
    feed(context, tool_result("toolu_2", "done"))

    assert.equals(2, registry.total_subagent_count())
  end)

  it("does not double-count a tool_use repeated across events (input streamed incrementally)", function()
    local registry = fresh_registry()
    registry.register({ handle_id = "h1", adapter = {} })
    local context = new_context("h1")

    feed(context, tool_use("toolu_1", "Task"))
    feed(context, tool_use("toolu_1", "Task"))

    assert.equals(1, registry.total_subagent_count())
  end)

  it("ignores ordinary tools", function()
    local registry = fresh_registry()
    registry.register({ handle_id = "h1", adapter = {} })
    local context = new_context("h1")

    feed(context, tool_use("toolu_1", "Bash"))
    feed(context, tool_result("toolu_1", "done"))

    assert.equals(0, registry.total_subagent_count())
  end)

  it("keeps two chats' subagent counts apart", function()
    local registry = fresh_registry()
    registry.register({ handle_id = "h1", adapter = {} })
    registry.register({ handle_id = "h2", adapter = {} })

    feed(new_context("h1"), tool_use("toolu_1", "Task"))
    feed(new_context("h2"), tool_use("toolu_2", "Task"))
    feed(new_context("h2"), tool_use("toolu_3", "Task"))

    assert.equals(3, registry.total_subagent_count())
  end)

  it("never attributes a nested subagent's own tool calls to the parent stream", function()
    -- A subagent's own assistant/user events carry parent_tool_use_id and bail out before the
    -- tool_use loop that counts subagent starts -- see cli_event_processor_subagent_spec.lua.
    local registry = fresh_registry()
    registry.register({ handle_id = "h1", adapter = {} })
    local context = new_context("h1")

    feed(context, tool_use("toolu_1", "Task"))
    feed(context, {
      type = "assistant",
      parent_tool_use_id = "toolu_1",
      message = {
        role = "assistant",
        content = { { type = "tool_use", id = "toolu_nested", name = "Task", input = {} } },
      },
    })

    assert.equals(1, registry.total_subagent_count())
  end)
end)
