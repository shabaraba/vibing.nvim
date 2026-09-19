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

      it("says out loud whether it registers chat_bufnr, rather than leaving it absent", function()
        -- Required explicitly, because an absent field and `false` mean the same thing to the code
        -- and very different things to a reader. This flag now decides two features — the
        -- `nvim_ask_user_question` route and whether an approval may be answered without killing
        -- the CLI — so a descriptor that simply omits it looks like nobody considered either.
        -- Same reason codex and grok write their missing floor as a comment instead of silence.
        assert.is_true(
          type(descriptor.register_chat_bufnr) == "boolean",
          def.id .. " must declare register_chat_bufnr as a boolean, not leave it to default"
        )
      end)

      it("may wait for an approval only when it is both measured and wired", function()
        -- The two fields read as independent — `measured_wait_floor_sec` times the hook,
        -- `register_chat_bufnr` is about `nvim_ask_user_question` — and nothing but this assertion
        -- connects them. Waiting needs both: `_ask_without_killing` names the chat through
        -- `turn.process.chat_bufnr`, and `cli_adapter` fills that in only when
        -- `register_chat_bufnr` is true. With the floor alone the waiting branch is still taken,
        -- finds nil, and denies every `ask` with an internal-error reason — **no prompt is drawn at
        -- all**. copilot shipped exactly that pair (floor 1700, `register_chat_bufnr = false`) and
        -- lost the Tool Approval UI it already had, with the whole suite green.
        --
        -- Asserted as an equality against the two raw fields, not as
        -- "can_wait_for_approval implies register_chat_bufnr": the gate now requires the flag, so
        -- that implication can no longer be made false and would pass no matter what the gate did.
        -- Recomputing the expected value from the descriptor is what keeps this able to fail.
        --
        -- A floor on an unwired backend is a legal descriptor — copilot's 1700s is a real
        -- measurement worth keeping recorded — so what is pinned is that the gate answers false for
        -- it, not that the pair cannot exist.
        local floor = descriptor.hook and descriptor.hook.measured_wait_floor_sec
        local measured = type(floor) == "number"
          and floor > require("vibing.infrastructure.hooks.wait_budget").script_wait_sec()
        local wired = descriptor.register_chat_bufnr == true

        assert.equals(
          measured and wired,
          Transports.can_wait_for_approval(descriptor),
          string.format(
            "%s: measured=%s wired=%s — waiting must be enabled by both, or its approvals turn"
              .. " into denials nobody was asked about",
            def.id,
            tostring(measured),
            tostring(wired)
          )
        )
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
