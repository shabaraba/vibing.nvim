---@diagnostic disable: undefined-field
--- What every backend descriptor has to declare for `cli_adapter` to drive it (ADR 009).
---
--- A missing field here does not fail loudly at runtime: a descriptor without `hook` runs every
--- turn ungated, one without `vocabulary` renders native tool names, one whose `request` has no
--- prompt part sends nothing. So the shape is pinned per registered backend.
local Agents = require("vibing.core.constants.agents")
local Transports = require("vibing.infrastructure.hooks.transports")

local PART_KINDS = { args = true, model = true, effort = true, resume = true, hook_arg = true, permission_mode = true, prompt = true, extra = true }
local PROCESS_MODELS = { "oneshot", "duplex" }

describe("conformance: descriptor shape", function()
  for _, def in ipairs(Agents.list()) do
    local descriptor = require(def.descriptor_module)

    describe(def.id, function()
      it("is registered under its own id and names the features the chat relies on", function()
        assert.equals(def.id, descriptor.id)
        assert.is_true(descriptor.features.streaming, "send_message only streams")
        assert.is_true(descriptor.features.session, "a chat that cannot resume is a new chat every turn")
        assert.is_true(descriptor.features.tools)
      end)

      it("has a request with a binary and well-formed parts, exactly one of them the prompt", function()
        local request = descriptor.request
        assert.is_table(request)
        assert.is_table(request.binary)
        assert.is_true(type(request.binary.name) == "string" or type(request.binary.resolve) == "function")
        local prompts = 0
        for index, part in ipairs(request.parts) do
          assert.is_true(PART_KINDS[part.kind] == true, string.format("part %d has unknown kind %s", index, tostring(part.kind)))
          if part.kind == "prompt" then
            prompts = prompts + 1
          end
          if part.kind == "extra" then
            assert.is_function(part.fn, string.format("part %d is an extra without fn", index))
          end
        end
        assert.equals(1, prompts)
      end)

      it("builds through the same engine its request declares", function()
        -- `build` is what cli_adapter calls; a descriptor whose build bypassed its own request
        -- spec would make the spec documentation rather than the argv.
        assert.is_function(descriptor.build)
      end)

      it("decodes through the shared renderer", function()
        assert.is_function(descriptor.event_processor.processLine)
        assert.is_table(descriptor.event_processor.decoder, "processor is not a stream_decoder facade")
      end)

      it("declares its hook transport and either a vocabulary or the canonical one", function()
        assert.is_table(descriptor.hook)
        assert.is_true(vim.tbl_contains(Transports.NAMES, descriptor.hook.transport))
        if descriptor.vocabulary then
          assert.is_function(descriptor.vocabulary.to_canonical)
        else
          assert.equals("claude", def.id, def.id .. " has no vocabulary but is not the canonical backend")
        end
      end)

      it("closes stdin or leaves it alone, nothing else", function()
        assert.is_true(descriptor.stdin == nil or descriptor.stdin == "")
      end)

      it("declares a process model it can actually run", function()
        -- `process` is a ceiling, not a default: absent means oneshot only. The two things a
        -- duplex-capable backend must not do are close the stdin its prompts arrive on, and keep
        -- the prompt in the argv (which would make the process answer once and exit) -- and both
        -- fail *quietly*, as a turn that never produces a second event.
        assert.is_true(descriptor.process == nil or vim.tbl_contains(PROCESS_MODELS, descriptor.process))
        if descriptor.process ~= "duplex" then
          return
        end
        assert.is_nil(descriptor.stdin, def.id .. " runs duplex but closes stdin")

        local prompt_part
        for _, part in ipairs(descriptor.request.parts) do
          if part.kind == "prompt" then
            prompt_part = part
          end
        end
        assert.equals("duplex", prompt_part.unless, def.id .. " keeps its prompt in the argv on duplex")
      end)
    end)
  end
end)
