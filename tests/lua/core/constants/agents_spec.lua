---@diagnostic disable: undefined-field
local Agents = require("vibing.core.constants.agents")

describe("agents registry", function()
  it("lists the backends in a fixed order", function()
    assert.same({ "claude", "codex", "copilot", "grok" }, Agents.ORDER)
  end)

  it("has a definition for every id in ORDER, and no strays", function()
    -- The drift this guards: an id in ORDER with no AGENTS entry used to pass validation and then
    -- fall back to claude without a word (#516).
    local defined = vim.tbl_keys(Agents.AGENTS)
    table.sort(defined)
    local ordered = vim.deepcopy(Agents.ORDER)
    table.sort(ordered)
    assert.same(ordered, defined)
  end)

  it("gives every backend a loadable adapter module and an export name", function()
    for _, def in ipairs(Agents.list()) do
      assert.is_string(def.adapter_module)
      assert.is_string(def.export_name)
      assert.is_true(pcall(require, def.adapter_module), def.adapter_module .. " does not load")
    end
  end)

  it("offers at least one model candidate per backend", function()
    for _, def in ipairs(Agents.list()) do
      assert.is_true(#def.models > 0, def.id .. " has no model candidates")
      for _, model in ipairs(def.models) do
        assert.is_string(model.value)
        assert.is_string(model.description)
      end
    end
  end)

  it("defaults to claude", function()
    assert.equals("claude", Agents.DEFAULT)
    assert.equals("claude", Agents.get(nil).id)
    assert.equals("claude", Agents.get("nonexistent").id)
  end)

  it("validates ids", function()
    assert.is_true(Agents.is_valid("codex"))
    assert.is_false(Agents.is_valid("nonexistent"))
    assert.is_false(Agents.is_valid(nil))
  end)

  describe("derived tables", function()
    it("is where modes.lua gets VALID_AGENTS from", function()
      local Modes = require("vibing.core.constants.modes")
      assert.same(Agents.ORDER, Modes.VALID_AGENTS)
    end)

    it("is where modes.lua gets the claude model names from", function()
      local Modes = require("vibing.core.constants.modes")
      local expected = vim.tbl_map(function(m)
        return m.value
      end, Agents.AGENTS.claude.models)
      assert.same(expected, Modes.VALID_MODELS)
    end)

    it("is where the frontmatter provider gets its agent enum from", function()
      local provider = require("vibing.infrastructure.completion.providers.frontmatter")
      local values = vim.tbl_map(function(item)
        return item.word
      end, provider.get_enum_values("agent"))
      assert.same(Agents.ORDER, values)
    end)

    it("is where the frontmatter provider gets its per-agent models from", function()
      local provider = require("vibing.infrastructure.completion.providers.frontmatter")
      for _, def in ipairs(Agents.list()) do
        local values = vim.tbl_map(function(item)
          return item.word
        end, provider.get_model_values(def.id))
        local expected = vim.tbl_map(function(m)
          return m.value
        end, def.models)
        assert.same(expected, values, def.id .. " model candidates drifted")
      end
    end)

    it("is where the factory resolves adapter modules from", function()
      local Factory = require("vibing.infrastructure.adapter.factory")
      for _, def in ipairs(Agents.list()) do
        assert.equals(def.adapter_module:match("[^.]+$"), Factory.adapter_name(def.id))
      end
    end)
  end)
end)
