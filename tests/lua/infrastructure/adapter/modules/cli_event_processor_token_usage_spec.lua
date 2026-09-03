describe("cli_event_processor token usage", function()
  local processor = require("vibing.infrastructure.adapter.modules.cli_event_processor")
  local TokenUsage = require("vibing.core.utils.token_usage")

  local function new_context()
    return {
      output = {},
      errorOutput = {},
      tokenUsage = TokenUsage.new(),
      _cached_display_mode = "full",
    }
  end

  local function assistant(usage, parent_tool_use_id)
    return vim.json.encode({
      type = "assistant",
      parent_tool_use_id = parent_tool_use_id or vim.NIL,
      message = {
        role = "assistant",
        content = { { type = "text", text = "hi" } },
        usage = usage,
      },
    })
  end

  it("records each assistant message's usage off the live stream", function()
    local context = new_context()

    processor.processLine(
      assistant({
        input_tokens = 2,
        cache_creation_input_tokens = 7537,
        cache_read_input_tokens = 116639,
        output_tokens = 877,
      }),
      context
    )
    processor.processLine(
      assistant({
        input_tokens = 2,
        cache_creation_input_tokens = 106496,
        cache_read_input_tokens = 20406,
        output_tokens = 491,
      }),
      context
    )

    assert.equals(2, context.tokenUsage.requests)
    -- Real numbers from this project's own logs: the second request is one that failed to reuse
    -- the cached prefix and re-wrote an identical 106k of it. Its prompt is the larger of the two,
    -- so that is the size the gauge reports.
    assert.equals(126904, context.tokenUsage.context)
    assert.equals(137045, context.tokenUsage.read)
    assert.equals(114033, context.tokenUsage.write)
  end)

  it("attributes a subagent's usage to the subagent, not to this chat's context", function()
    local context = new_context()

    processor.processLine(
      assistant({ input_tokens = 2, cache_creation_input_tokens = 0, cache_read_input_tokens = 200000, output_tokens = 10 }),
      context
    )
    processor.processLine(
      assistant(
        { input_tokens = 2, cache_creation_input_tokens = 0, cache_read_input_tokens = 80000, output_tokens = 10 },
        "toolu_sub_1"
      ),
      context
    )

    assert.equals(1, context.tokenUsage.requests)
    assert.equals(1, context.tokenUsage.subagent_requests)
    assert.equals(200002, context.tokenUsage.context)
    assert.equals(280000, context.tokenUsage.read)
  end)

  it("treats a top-level null parent_tool_use_id as main-chain", function()
    -- vim.json.decode turns JSON null into vim.NIL, which is truthy in Lua -- reading the field
    -- directly would file every ordinary reply under "subagent".
    local context = new_context()

    processor.processLine(
      assistant({ input_tokens = 1, cache_creation_input_tokens = 0, cache_read_input_tokens = 1000, output_tokens = 1 }),
      context
    )

    assert.equals(1, context.tokenUsage.requests)
    assert.equals(0, context.tokenUsage.subagent_requests)
  end)

  it("processes a stream that carries no accumulator at all", function()
    -- Other backends' contexts never set tokenUsage; recording must stay optional.
    local context = new_context()
    context.tokenUsage = nil

    assert.has_no.errors(function()
      processor.processLine(assistant({ input_tokens = 1, output_tokens = 1 }), context)
    end)
  end)
end)
