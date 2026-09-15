---@diagnostic disable: undefined-field
--- The shared renderer (ADR 009 P1): what every backend's canonical events turn into.
local Renderer = require("vibing.infrastructure.adapter.modules.event_renderer")

describe("event_renderer", function()
  local function new_context(overrides)
    return vim.tbl_extend("force", {
      output = {},
      errorOutput = {},
      opts = {},
      _cached_markers = false,
      _cached_display_mode = "full",
      _cached_show_prefix = false,
    }, overrides or {})
  end

  local function output(context)
    return table.concat(context.output, "")
  end

  local function drain()
    vim.wait(50, function()
      return false
    end)
  end

  describe("tool calls", function()
    it("draws the header with the result, the way claude's stream does", function()
      local context = new_context()
      Renderer.handle({ kind = "tool_start", id = "t1", name = "Bash", input = { command = "ls" } }, context)
      assert.equals("", output(context), "nothing is drawn until the result lands")
      Renderer.handle({ kind = "tool_end", id = "t1", result = "a.txt" }, context)
      assert.equals("\n⏺ Bash(ls)\n  ⎿  a.txt\n", output(context))
    end)

    it("ignores a result for a tool it never saw start", function()
      local context = new_context()
      Renderer.handle({ kind = "tool_end", id = "ghost", result = "x" }, context)
      assert.equals("", output(context))
    end)

    it("canonicalises the name and the path through the backend vocabulary", function()
      local context = new_context({
        vocabulary = require("vibing.infrastructure.adapter.modules.copilot_tool_vocabulary"),
      })
      local seen = nil
      context.opts.on_tool_use = function(tool, file_path, command)
        seen = { tool = tool, file_path = file_path, command = command }
      end
      Renderer.handle({ kind = "tool_start", id = "t1", name = "edit", input = { path = "a.lua" } }, context)
      Renderer.handle({ kind = "tool_end", id = "t1", result = "" }, context)
      drain()
      assert.same({ tool = "Edit", file_path = "a.lua" }, seen)
      assert.equals("\n⏺ Edit(a.lua)\n", output(context))
    end)

    it("reports each path of a multi-file change on its own", function()
      -- codex's apply_patch names several files in one item; send_message keys its modified
      -- file set on one path per call.
      local context = new_context({
        vocabulary = require("vibing.infrastructure.adapter.modules.codex_tool_vocabulary"),
      })
      local calls = {}
      context.opts.on_tool_use = function(tool, file_path)
        table.insert(calls, tool .. ":" .. tostring(file_path))
      end
      Renderer.handle(
        { kind = "tool_start", id = "t1", name = "apply_patch", input = { file_paths = { "a.lua", "b.lua" } } },
        context
      )
      Renderer.handle({ kind = "tool_end", id = "t1", result = "modified a.lua\ncreated b.lua" }, context)
      drain()
      assert.same({ "Edit:a.lua", "Edit:b.lua" }, calls)
      assert.equals("\n⏺ Edit(a.lua, b.lua)\n  ⎿  modified a.lua\n     created b.lua\n", output(context))
    end)

    it("fires on_tool_use once per tool id however often the start is repeated", function()
      local context = new_context()
      local count = 0
      context.opts.on_tool_use = function()
        count = count + 1
      end
      local start = { kind = "tool_start", id = "t1", name = "Read", input = { file_path = "x" } }
      Renderer.handle(start, context)
      Renderer.handle(start, context)
      drain()
      assert.equals(1, count)
    end)

    it("prefixes a failed result with Error: exactly once", function()
      local context = new_context()
      Renderer.handle({ kind = "tool_start", id = "t1", name = "Bash", input = { command = "x" } }, context)
      Renderer.handle({ kind = "tool_end", id = "t1", result = "denied", is_error = true }, context)
      assert.equals("\n⏺ Bash(x)\n  ⎿  Error: denied\n", output(context))

      local again = new_context()
      Renderer.handle({ kind = "tool_start", id = "t1", name = "Bash", input = { command = "x" } }, again)
      Renderer.handle({ kind = "tool_end", id = "t1", result = "Error: denied", is_error = true }, again)
      assert.equals("\n⏺ Bash(x)\n  ⎿  Error: denied\n", output(again))
    end)

    it("passes the untouched input to on_tool_use_full", function()
      local context = new_context()
      local seen = nil
      context.opts.on_tool_use_full = function(_, input)
        seen = input
      end
      Renderer.handle({ kind = "tool_start", id = "t1", name = "Bash", input = { command = "x", extra = 1 } }, context)
      drain()
      assert.same({ command = "x", extra = 1 }, seen)
    end)
  end)

  describe("thinking", function()
    it("opens a 💭 block once and closes it when prose resumes", function()
      local context = new_context()
      Renderer.handle({ kind = "thinking", delta = "a" }, context)
      Renderer.handle({ kind = "thinking", delta = "b" }, context)
      Renderer.handle({ kind = "text", delta = "c" }, context)
      Renderer.handle({ kind = "thinking", delta = "d" }, context)
      assert.equals("\n💭 ab\n\nc\n💭 d", output(context))
    end)

    it("is closed by a tool result without an extra separator", function()
      local context = new_context()
      Renderer.handle({ kind = "thinking", delta = "a" }, context)
      Renderer.handle({ kind = "tool_start", id = "t1", name = "Bash", input = { command = "x" } }, context)
      Renderer.handle({ kind = "tool_end", id = "t1", result = "" }, context)
      Renderer.handle({ kind = "text", delta = "c" }, context)
      assert.equals("\n💭 a\n⏺ Bash(x)\nc", output(context))
    end)
  end)

  describe("errors", function()
    it("drops an immediate repeat but keeps a later one", function()
      local context = new_context()
      Renderer.handle({ kind = "error", message = "limit" }, context)
      Renderer.handle({ kind = "error", message = "limit" }, context)
      Renderer.handle({ kind = "error", message = "other" }, context)
      Renderer.handle({ kind = "error", message = "limit" }, context)
      assert.same({ "limit", "other", "limit" }, context.errorOutput)
    end)

    it("records a fatal error where the exit handler reads a failed turn", function()
      local context = new_context()
      Renderer.handle({ kind = "error", message = "warn" }, context)
      assert.is_nil(context.resultErrors)
      Renderer.handle({ kind = "error", message = "dead", fatal = true }, context)
      assert.same({ "dead" }, context.resultErrors)
    end)
  end)

  describe("usage", function()
    it("accumulates per-request records, creating the accumulator on demand", function()
      local context = new_context()
      Renderer.handle({ kind = "usage", record = { input_tokens = 1, output_tokens = 2 } }, context)
      Renderer.handle({ kind = "usage", record = { input_tokens = 1, output_tokens = 2 } }, context)
      assert.equals(2, context.tokenUsage.requests)
    end)

    it("replaces the accumulator when a backend reports a whole-turn total", function()
      local context = new_context()
      local total = { backend = "codex", totals = {} }
      Renderer.handle({ kind = "usage", accumulator = total }, context)
      assert.equals(total, context.tokenUsage)
    end)
  end)

  describe("cli_info", function()
    it("merges fields and stamps started_at only once", function()
      local context = new_context()
      Renderer.handle({ kind = "cli_info", version = "2.1.231", tools = 4 }, context)
      local first = context.cliInfo.started_at
      Renderer.handle({ kind = "cli_info", compacted = true }, context)
      Renderer.handle({ kind = "cli_info", version = "2.1.231" }, context)
      assert.equals("2.1.231", context.cliInfo.version)
      assert.equals(4, context.cliInfo.tools)
      assert.is_true(context.cliInfo.compacted)
      assert.equals(first, context.cliInfo.started_at)
    end)
  end)

  it("ignores an event kind it does not know", function()
    local context = new_context()
    assert.has_no.errors(function()
      Renderer.handle({ kind = "future" }, context)
      Renderer.handle(nil, context)
    end)
    assert.equals("", output(context))
  end)
end)
