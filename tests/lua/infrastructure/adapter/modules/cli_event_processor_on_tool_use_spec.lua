describe("cli_event_processor on_tool_use path resolution", function()
  local processor = require("vibing.infrastructure.adapter.modules.cli_event_processor")

  local function feed(context, event)
    processor.processLine(vim.json.encode(event), context)
  end

  local function tool_use_event(id, name, input)
    return {
      type = "assistant",
      message = {
        role = "assistant",
        content = { { type = "tool_use", id = id, name = name, input = input } },
      },
    }
  end

  ---on_tool_use fires through vim.schedule, so drain it before asserting.
  local function drain()
    vim.wait(50, function()
      return false
    end)
  end

  it("passes notebook_path as the file_path for NotebookEdit", function()
    local calls = {}
    local context = {
      output = {},
      errorOutput = {},
      opts = {
        on_tool_use = function(tool, file_path, command)
          table.insert(calls, { tool = tool, file_path = file_path, command = command })
        end,
      },
    }

    feed(context, tool_use_event("toolu_1", "NotebookEdit", { notebook_path = "/tmp/notebook.ipynb" }))
    drain()

    assert.equals(1, #calls)
    assert.equals("NotebookEdit", calls[1].tool)
    assert.equals("/tmp/notebook.ipynb", calls[1].file_path)
  end)

  it("still prefers file_path when both are present", function()
    local calls = {}
    local context = {
      output = {},
      errorOutput = {},
      opts = {
        on_tool_use = function(tool, file_path, command)
          table.insert(calls, { tool = tool, file_path = file_path, command = command })
        end,
      },
    }

    feed(
      context,
      tool_use_event("toolu_2", "Write", { file_path = "/tmp/a.lua", notebook_path = "/tmp/should-not-use.ipynb" })
    )
    drain()

    assert.equals(1, #calls)
    assert.equals("/tmp/a.lua", calls[1].file_path)
  end)
end)
