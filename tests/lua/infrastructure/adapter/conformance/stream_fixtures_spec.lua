---@diagnostic disable: undefined-field
--- Contracts C1 and C3 of ADR 009 against real captures: every file under
--- `tests/fixtures/streams/<backend>/` is replayed through the backend's own processor and the
--- shared renderer. See `tests/fixtures/streams/README.md` for what a fixture is.
local Agents = require("vibing.core.constants.agents")
local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")

local ROOT = vim.fn.getcwd() .. "/tests/fixtures/streams"

describe("conformance: stream fixtures", function()
  for _, def in ipairs(Agents.list()) do
    local dir = ROOT .. "/" .. def.id
    local files = vim.fn.glob(dir .. "/*.jsonl", false, true)

    describe(def.id, function()
      it("has at least one capture", function()
        -- Reported, not skipped: a backend with no capture is a backend whose decoder was never
        -- checked against its CLI. Marked pending so the gap is visible in the run without
        -- failing a suite that the other backends pass.
        if #files == 0 then
          pending(def.id .. ": no stream capture under " .. dir .. " (see the fixtures README)")
        end
      end)

      for _, file in ipairs(files) do
        it("replays " .. vim.fn.fnamemodify(file, ":t"), function()
          local processor = require(def.descriptor_module).event_processor
          local context = {
            sessionManager = SessionManagerModule.new(),
            handleId = "fixture",
            output = {},
            errorOutput = {},
            opts = {},
            onChunk = function() end,
            _cached_markers = false,
            _cached_display_mode = "full",
            _cached_show_prefix = false,
          }
          local lines = vim.fn.readfile(file)
          assert.is_true(#lines > 0)
          local processed = 0
          for _, line in ipairs(lines) do
            if processor.processLine(line, context) then
              processed = processed + 1
            end
          end
          vim.wait(50, function()
            return false
          end)

          assert.is_true(processed > 0, "no line of the capture was understood")
          assert.is_not_nil(SessionManagerModule.get(context.sessionManager, "fixture"), "no session id learned")
          assert.is_true(#table.concat(context.output, "") > 0, "nothing reached the chat")
          -- Every tool that started has ended: a leftover entry is a header that never rendered.
          assert.same({}, context._tools or {}, "a tool call started and never ended")
        end)
      end
    end)
  end
end)
