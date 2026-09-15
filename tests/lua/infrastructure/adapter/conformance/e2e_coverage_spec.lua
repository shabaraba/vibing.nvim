---@diagnostic disable: undefined-field
--- Every registered backend is driven by an E2E spec that runs a real turn on it.
---
--- The rest of the conformance suite reports its own gaps: `hook_payload_spec` fails on a backend
--- with no recorded payload, `stream_fixtures_spec` marks a missing capture pending. The E2E layer
--- had no equivalent, and it is the only check that can tell whether *today's* CLI still emits the
--- shapes the fixtures were captured from -- so a fifth descriptor would go green across the whole
--- suite with no real turn ever run against it, and nothing would say so.
---
--- This is a source check rather than a run: E2E costs real tokens and only `test:e2e` runs it,
--- while the gap is worth reporting on every `test:lua`.
local Agents = require("vibing.core.constants.agents")

local ROOT = vim.fn.getcwd()

--- Backends whose coverage does not come from `spawn_backend_instance`, and where it comes from
--- instead. Only the default backend qualifies: every ordinary E2E spec already runs it. Named
--- here rather than skipped silently, and checked against `Agents.DEFAULT` below so that changing
--- the default moves the exemption instead of stranding it.
local COVERED_AS_DEFAULT = { claude = "tests/e2e/chat_basic_flow_spec.lua" }

--- @return string every E2E spec's source, concatenated
local function e2e_sources()
  local sources = {}
  for _, file in ipairs(vim.fn.glob(ROOT .. "/tests/e2e/*.lua", false, true)) do
    table.insert(sources, table.concat(vim.fn.readfile(file), "\n"))
  end
  return table.concat(sources, "\n")
end

describe("conformance: E2E coverage", function()
  local sources = e2e_sources()

  for _, def in ipairs(Agents.list()) do
    describe(def.id, function()
      it("is driven by an E2E spec", function()
        local covered_by = COVERED_AS_DEFAULT[def.id]
        if covered_by then
          assert.equals(
            Agents.DEFAULT,
            def.id,
            def.id .. " is exempt as the default backend, but the default is now " .. tostring(Agents.DEFAULT)
          )
          assert.equals(1, vim.fn.filereadable(ROOT .. "/" .. covered_by), covered_by .. " no longer exists")
          return
        end

        local call = string.format('spawn_backend_instance("%s")', def.id)
        assert.is_not_nil(
          sources:find(call, 1, true),
          string.format(
            "no spec under tests/e2e/ calls %s. Adding a backend means adding one, or this backend "
              .. "is never run against its real CLI (see tests/fixtures/streams/README.md).",
            call
          )
        )
      end)
    end)
  end
end)
