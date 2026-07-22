local grok_event_processor = require("vibing.infrastructure.adapter.modules.grok_event_processor")
local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")

describe("grok_event_processor", function()
  local function make_context()
    return {
      sessionManager = SessionManagerModule.new(),
      handleId = "handle-1",
      output = {},
      errorOutput = {},
      chunks = {},
      first_response_calls = 0,
      onFirstResponse = nil,
      onChunk = nil,
    }
  end

  local function new_context()
    local context = make_context()
    context.onFirstResponse = function()
      context.first_response_calls = context.first_response_calls + 1
    end
    context.onChunk = function(chunk)
      table.insert(context.chunks, chunk)
    end
    return context
  end

  local function line(tbl)
    return vim.json.encode(tbl)
  end

  local function flush()
    vim.wait(20)
  end

  it("emits text deltas as-is and calls onFirstResponse", function()
    local context = new_context()
    grok_event_processor.processLine(line({ type = "text", data = "Hello" }), context)
    flush()

    assert.equals(1, context.first_response_calls)
    assert.equals("Hello", table.concat(context.chunks, ""))
  end)

  it("prefixes the first thought delta with a marker but not subsequent ones", function()
    local context = new_context()
    grok_event_processor.processLine(line({ type = "thought", data = "The" }), context)
    grok_event_processor.processLine(line({ type = "thought", data = " user" }), context)
    flush()

    local combined = table.concat(context.chunks, "")
    assert.equals("\n💭 The user", combined)
  end)

  it("inserts a separator when switching from thought to text", function()
    local context = new_context()
    grok_event_processor.processLine(line({ type = "thought", data = "thinking" }), context)
    grok_event_processor.processLine(line({ type = "text", data = "answer" }), context)
    flush()

    local combined = table.concat(context.chunks, "")
    assert.equals("\n💭 thinking\n\nanswer", combined)
  end)

  it("does not re-emit the thought marker after switching back from text", function()
    local context = new_context()
    grok_event_processor.processLine(line({ type = "thought", data = "a" }), context)
    grok_event_processor.processLine(line({ type = "text", data = "b" }), context)
    grok_event_processor.processLine(line({ type = "thought", data = "c" }), context)
    flush()

    local combined = table.concat(context.chunks, "")
    assert.equals("\n💭 a\n\nb\n💭 c", combined)
  end)

  it("stores the session id from the end event without emitting a chunk", function()
    local context = new_context()
    grok_event_processor.processLine(
      line({ type = "end", stopReason = "EndTurn", sessionId = "session-xyz" }),
      context
    )
    flush()

    assert.equals("session-xyz", SessionManagerModule.get(context.sessionManager, "handle-1"))
    assert.equals(0, #context.chunks)
  end)

  it("collects error messages from an error event", function()
    local context = new_context()
    grok_event_processor.processLine(line({ type = "error", message = "boom" }), context)

    assert.equals("boom", context.errorOutput[1])
  end)

  it("ignores unknown event types without erroring", function()
    local context = new_context()
    local ok = grok_event_processor.processLine(line({ type = "some_future_event" }), context)
    assert.is_true(ok)
  end)

  it("returns false for unparsable lines", function()
    local context = new_context()
    assert.is_false(grok_event_processor.processLine("not json", context))
    assert.is_false(grok_event_processor.processLine("", context))
  end)
end)
