describe("cli_event_processor subagent text", function()
  local processor = require("vibing.infrastructure.adapter.modules.cli_event_processor")

  local TOOL_ID = "toolu_sub_1"

  ---A context wired so emitted chunks land in a table we can assert on.
  ---@param show_prefix boolean|nil label each forwarded line with the subagent type
  ---@return table context
  ---@return string[] chunks
  local function new_context(show_prefix)
    local chunks = {}
    local context = {
      output = {},
      errorOutput = {},
      onChunk = function(text)
        table.insert(chunks, text)
      end,
      -- Pre-seed the caches so the spec never reaches the real config or user highlight setup.
      _cached_display_mode = "full",
      _cached_show_prefix = show_prefix == true,
    }
    return context, chunks
  end

  local function feed(context, event)
    processor.processLine(vim.json.encode(event), context)
  end

  local function parent_tool_use()
    return {
      type = "assistant",
      message = {
        role = "assistant",
        content = {
          {
            type = "tool_use",
            id = TOOL_ID,
            name = "Agent",
            input = { subagent_type = "explorer", prompt = "look around" },
          },
        },
      },
    }
  end

  local function subagent_text(text)
    return {
      type = "assistant",
      parent_tool_use_id = TOOL_ID,
      message = { role = "assistant", content = { { type = "text", text = text } } },
    }
  end

  local function tool_result(content)
    return {
      type = "user",
      message = {
        role = "user",
        content = { { type = "tool_result", tool_use_id = TOOL_ID, content = content } },
      },
    }
  end

  ---Chunks are delivered through vim.schedule, so drain the scheduler before asserting.
  local function drain()
    vim.wait(50, function()
      return false
    end)
  end

  it("renders subagent text above the tool result it produced", function()
    local context, chunks = new_context()

    feed(context, parent_tool_use())
    feed(context, subagent_text("BANANA"))
    feed(context, tool_result("done"))
    drain()

    assert.equals(1, #chunks)
    local text = chunks[1]
    assert.is_truthy(text:find("Agent(explorer)", 1, true))
    assert.is_truthy(text:find("  │ BANANA", 1, true))
    -- The subagent's reasoning must precede the conclusion it produced.
    assert.is_true(text:find("BANANA", 1, true) < text:find("done", 1, true))
  end)

  it("labels each line when show_prefix is on", function()
    local context, chunks = new_context(true)

    feed(context, parent_tool_use())
    feed(context, subagent_text("first\nsecond"))
    feed(context, tool_result("done"))
    drain()

    assert.is_truthy(chunks[1]:find("  │ [explorer] first", 1, true))
    assert.is_truthy(chunks[1]:find("  │ [explorer] second", 1, true))
  end)

  it("concatenates multiple subagent messages in arrival order", function()
    local context, chunks = new_context()

    feed(context, parent_tool_use())
    feed(context, subagent_text("one "))
    feed(context, subagent_text("two"))
    feed(context, tool_result("done"))
    drain()

    assert.is_truthy(chunks[1]:find("  │ one two", 1, true))
  end)

  it("keeps each subagent's text with its own tool call", function()
    local context, chunks = new_context()

    feed(context, parent_tool_use())
    feed(context, {
      type = "assistant",
      message = {
        role = "assistant",
        content = {
          { type = "tool_use", id = "toolu_sub_2", name = "Agent", input = { subagent_type = "reviewer" } },
        },
      },
    })
    feed(context, subagent_text("from one"))
    feed(context, {
      type = "assistant",
      parent_tool_use_id = "toolu_sub_2",
      message = { role = "assistant", content = { { type = "text", text = "from two" } } },
    })
    feed(context, tool_result("result one"))
    drain()

    assert.is_truthy(chunks[1]:find("from one", 1, true))
    assert.is_nil(chunks[1]:find("from two", 1, true))
  end)

  it("ignores the prompt echo and thinking blocks", function()
    local context, chunks = new_context()

    feed(context, parent_tool_use())
    -- The `user` event is the prompt the parent already showed in the tool header.
    feed(context, {
      type = "user",
      parent_tool_use_id = TOOL_ID,
      message = { role = "user", content = { { type = "text", text = "ECHOED PROMPT" } } },
    })
    feed(context, {
      type = "assistant",
      parent_tool_use_id = TOOL_ID,
      message = { role = "assistant", content = { { type = "thinking", thinking = "PRIVATE" } } },
    })
    feed(context, tool_result("done"))
    drain()

    assert.is_nil(chunks[1]:find("ECHOED PROMPT", 1, true))
    assert.is_nil(chunks[1]:find("PRIVATE", 1, true))
  end)

  it("leaves the parent's own streaming text untouched", function()
    local context, chunks = new_context()

    feed(context, {
      type = "stream_event",
      event = { type = "content_block_delta", delta = { type = "text_delta", text = "parent says hi" } },
    })
    drain()

    assert.equals(1, #chunks)
    assert.equals("parent says hi", chunks[1])
  end)

  it("renders the plain tool result when no subagent text arrived", function()
    local context, chunks = new_context()

    feed(context, parent_tool_use())
    feed(context, tool_result("done"))
    drain()

    assert.is_truthy(chunks[1]:find("Agent(explorer)", 1, true))
    assert.is_nil(chunks[1]:find("│", 1, true))
  end)

  it("treats an explicit null parent_tool_use_id as the parent's own message", function()
    local context, chunks = new_context()

    -- Every top-level event in a real stream carries `"parent_tool_use_id": null`, which decodes
    -- to vim.NIL — truthy in Lua. Reading the field directly would route all of these into the
    -- subagent buffer and suppress tool results entirely.
    processor.processLine(
      vim.json.encode(vim.tbl_extend("force", parent_tool_use(), { parent_tool_use_id = vim.NIL })),
      context
    )
    processor.processLine(
      vim.json.encode(vim.tbl_extend("force", tool_result("done"), { parent_tool_use_id = vim.NIL })),
      context
    )
    drain()

    assert.equals(1, #chunks)
    assert.is_truthy(chunks[1]:find("Agent(explorer)", 1, true))
  end)

  it("replays a real CLI stream capture", function()
    local fixture = vim.fn.getcwd() .. "/tests/fixtures/subagent_stream.jsonl"
    local lines = vim.fn.readfile(fixture)
    assert.is_true(#lines > 0)

    local context, chunks = new_context()
    for _, line in ipairs(lines) do
      processor.processLine(line, context)
    end
    drain()

    local joined = table.concat(chunks, "")
    assert.is_truthy(joined:find("  │ ", 1, true))
  end)
end)
