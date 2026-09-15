---@diagnostic disable: undefined-field
--- Contract C2 of ADR 009: a tool call looks the same in the chat whichever CLI ran it.
---
--- Each backend is fed the line its own CLI would emit for "run `ls`, get `a.txt`", through the
--- processor its descriptor registers, and the rendered text has to be byte-identical to claude's.
--- Grok is absent because its streaming-json carries no tool events at all -- a fact about the
--- CLI, recorded in `decoders/grok_streaming_json.lua`.
local Agents = require("vibing.core.constants.agents")

local EXPECTED = "\n⏺ Bash(ls)\n  ⎿  a.txt\n"

--- The same tool call, in each CLI's own stream shape (captured shapes, trimmed).
local STREAMS = {
  claude = {
    { type = "assistant", parent_tool_use_id = vim.NIL, message = { content = { { type = "tool_use", id = "t1", name = "Bash", input = { command = "ls" } } } } },
    { type = "user", parent_tool_use_id = vim.NIL, message = { content = { { type = "tool_result", tool_use_id = "t1", content = "a.txt" } } } },
  },
  codex = {
    { type = "item.started", item = { id = "t1", type = "command_execution", command = "/bin/bash -lc 'ls'" } },
    { type = "item.completed", item = { id = "t1", type = "command_execution", command = "/bin/bash -lc 'ls'", aggregated_output = "a.txt" } },
  },
  copilot = {
    { type = "tool.execution_start", data = { toolCallId = "t1", toolName = "bash", arguments = { command = "ls" } } },
    { type = "tool.execution_complete", data = { toolCallId = "t1", success = true, result = { content = "a.txt" } } },
  },
}

describe("conformance: tool rendering parity", function()
  for _, def in ipairs(Agents.list()) do
    local stream = STREAMS[def.id]
    if stream then
      it(def.id .. " renders a shell call exactly as claude does", function()
        local processor = require(def.descriptor_module).event_processor
        local context = { output = {}, errorOutput = {}, opts = {}, _cached_markers = false, _cached_display_mode = "full" }
        local seen = nil
        context.opts.on_tool_use = function(tool, file_path, command)
          seen = { tool = tool, file_path = file_path, command = command }
        end

        for _, msg in ipairs(stream) do
          assert.is_true(processor.processLine(vim.json.encode(msg), context))
        end
        vim.wait(50, function()
          return false
        end)

        assert.equals(EXPECTED, table.concat(context.output, ""))
        assert.same({ tool = "Bash", command = "ls" }, seen)
      end)
    end
  end
end)
