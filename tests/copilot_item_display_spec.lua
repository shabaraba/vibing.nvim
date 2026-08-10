local ItemDisplay = require("vibing.infrastructure.adapter.modules.copilot_item_display")

describe("copilot_item_display", function()
  ---表示モードを固定した context を作る
  ---@return table
  local function make_context()
    return { _cached_markers = false, _cached_display_mode = "full" }
  end

  describe("resolve_label", function()
    it("maps bash to Bash", function()
      assert.are.equal("Bash", ItemDisplay.resolve_label("bash"))
    end)

    it("returns unknown tool names unchanged", function()
      assert.are.equal("some_future_tool", ItemDisplay.resolve_label("some_future_tool"))
    end)
  end)

  describe("summarize_arguments", function()
    it("prefers command and reports the command kind", function()
      local summary, kind = ItemDisplay.summarize_arguments({ command = "ls -la", description = "x" })
      assert.are.equal("ls -la", summary)
      assert.are.equal("command", kind)
    end)

    it("uses path and reports the path kind", function()
      local summary, kind = ItemDisplay.summarize_arguments({ path = "lua/init.lua" })
      assert.are.equal("lua/init.lua", summary)
      assert.are.equal("path", kind)
    end)

    it("uses file_path and reports the path kind", function()
      local summary, kind = ItemDisplay.summarize_arguments({ file_path = "a/b.lua" })
      assert.are.equal("a/b.lua", summary)
      assert.are.equal("path", kind)
    end)

    it("falls back to encoded json with the other kind", function()
      local summary, kind = ItemDisplay.summarize_arguments({ query = "vibing" })
      assert.are.equal("other", kind)
      assert.is_true(summary:find("vibing", 1, true) ~= nil)
    end)

    it("returns an empty summary for nil", function()
      local summary, kind = ItemDisplay.summarize_arguments(nil)
      assert.are.equal("", summary)
      assert.are.equal("other", kind)
    end)
  end)

  describe("extract_result_text", function()
    it("reads a string result", function()
      assert.are.equal("done", ItemDisplay.extract_result_text({ result = "done" }))
    end)

    it("reads result.content", function()
      assert.are.equal("hello\n", ItemDisplay.extract_result_text({ result = { content = "hello\n" } }))
    end)

    it("reads the error field when there is no result", function()
      assert.are.equal("boom", ItemDisplay.extract_result_text({ error = "boom" }))
    end)

    it("returns an empty string with no usable field", function()
      assert.are.equal("", ItemDisplay.extract_result_text({}))
    end)
  end)

  describe("format_execution_start", function()
    it("renders a header with the label and summary", function()
      local text = ItemDisplay.format_execution_start({
        toolName = "bash",
        arguments = { command = "ls -la" },
      }, make_context())
      assert.are.equal("\n⏺ Bash(ls -la)\n", text)
    end)

    it("renders unknown tools with their raw name", function()
      local text = ItemDisplay.format_execution_start({
        toolName = "future_tool",
        arguments = { path = "x.lua" },
      }, make_context())
      assert.are.equal("\n⏺ future_tool(x.lua)\n", text)
    end)
  end)

  describe("format_execution_complete", function()
    it("renders the result body", function()
      local text = ItemDisplay.format_execution_complete({
        success = true,
        result = { content = "hello" },
      }, make_context())
      assert.are.equal("  ⎿  hello\n", text)
    end)

    it("prefixes Error when the tool failed", function()
      local text = ItemDisplay.format_execution_complete({
        success = false,
        error = "permission denied",
      }, make_context())
      assert.are.equal("  ⎿  Error: permission denied\n", text)
    end)

    it("returns an empty string when there is nothing to show", function()
      local text = ItemDisplay.format_execution_complete({ success = true }, make_context())
      assert.are.equal("", text)
    end)
  end)
end)
