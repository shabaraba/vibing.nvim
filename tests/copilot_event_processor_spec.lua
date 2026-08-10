local Processor = require("vibing.infrastructure.adapter.modules.copilot_event_processor")
local SessionManager = require("vibing.infrastructure.adapter.modules.session_manager")

describe("copilot_event_processor", function()
  local context

  before_each(function()
    context = {
      sessionManager = SessionManager.new(),
      handleId = "handle-1",
      opts = {},
      output = {},
      errorOutput = {},
      _cached_markers = false,
      _cached_display_mode = "full",
    }
  end)

  ---イベントを JSON 行にして処理する
  ---@param event table
  local function process(event)
    Processor.processLine(vim.json.encode(event), context)
  end

  ---output バッファを連結して返す
  ---@return string
  local function output_text()
    return table.concat(context.output, "")
  end

  it("ignores blank and malformed lines", function()
    assert.is_false(Processor.processLine("", context))
    assert.is_false(Processor.processLine("not json", context))
  end)

  it("fires onFirstResponse on assistant.turn_start", function()
    local fired = false
    context.onFirstResponse = function()
      fired = true
    end
    process({ type = "assistant.turn_start", data = { turnId = "0" } })
    assert.is_true(fired)
  end)

  it("emits delta content in order", function()
    process({ type = "assistant.message_delta", data = { messageId = "m1", deltaContent = "he" } })
    process({ type = "assistant.message_delta", data = { messageId = "m1", deltaContent = "llo" } })
    assert.are.equal("hello", output_text())
  end)

  it("does not re-emit a message whose deltas were already streamed", function()
    process({ type = "assistant.message_delta", data = { messageId = "m1", deltaContent = "hello" } })
    process({ type = "assistant.message", data = { messageId = "m1", content = "hello" } })
    assert.are.equal("hello", output_text())
  end)

  it("emits assistant.message content when no delta arrived", function()
    process({ type = "assistant.message", data = { messageId = "m2", content = "hello" } })
    assert.are.equal("hello", output_text())
  end)

  it("ignores an assistant.message with empty content", function()
    process({ type = "assistant.message", data = { messageId = "m3", content = "" } })
    assert.are.equal("", output_text())
  end)

  it("stores the session id from the result event", function()
    process({ type = "result", sessionId = "sess-abc", exitCode = 0 })
    assert.are.equal("sess-abc", SessionManager.get(context.sessionManager, "handle-1"))
  end)

  it("renders tool execution start and complete", function()
    process({
      type = "tool.execution_start",
      data = { toolCallId = "t1", toolName = "bash", arguments = { command = "ls" } },
    })
    process({
      type = "tool.execution_complete",
      data = { toolCallId = "t1", success = true, result = { content = "a.txt" } },
    })
    assert.are.equal("\n⏺ Bash(ls)\n  ⎿  a.txt\n", output_text())
  end)

  it("reports a bash tool call through on_tool_use as a command", function()
    local seen = nil
    context.opts.on_tool_use = function(tool, file_path, command)
      seen = { tool = tool, file_path = file_path, command = command }
    end
    process({
      type = "tool.execution_start",
      data = { toolName = "bash", arguments = { command = "ls -la" } },
    })
    vim.wait(100, function()
      return seen ~= nil
    end, 10)
    assert.are.same({ tool = "Bash", file_path = nil, command = "ls -la" }, seen)
  end)

  it("reports a path-shaped tool call through on_tool_use as a file path", function()
    local seen = nil
    context.opts.on_tool_use = function(tool, file_path, command)
      seen = { tool = tool, file_path = file_path, command = command }
    end
    process({
      type = "tool.execution_start",
      data = { toolName = "edit_file", arguments = { path = "lua/init.lua" } },
    })
    vim.wait(100, function()
      return seen ~= nil
    end, 10)
    assert.are.same({ tool = "edit_file", file_path = "lua/init.lua", command = nil }, seen)
  end)

  it("collects error events into errorOutput", function()
    process({ type = "error", data = { message = "rate limited" } })
    assert.are.equal("rate limited", table.concat(context.errorOutput, ""))
  end)

  it("ignores unrelated event types", function()
    assert.is_true(Processor.processLine(
      vim.json.encode({ type = "session.mcp_server_status_changed", data = {} }),
      context
    ))
    assert.are.equal("", output_text())
  end)
end)
