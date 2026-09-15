---@diagnostic disable: undefined-field
--- The descriptor-driven adapter class (ADR 009). What the four adapter files used to each state
--- for themselves -- the instance name, the feature table, the class identity -- now derives from
--- the descriptor, and these pin that derivation.
local CliAdapter = require("vibing.infrastructure.adapter.cli_adapter")
local Agents = require("vibing.core.constants.agents")

describe("cli_adapter", function()
  it("builds one class per descriptor id and hands the same one back", function()
    -- A throwaway id: `define` memoises per id for the life of the process, so defining a bare
    -- descriptor under a real backend's id here would replace that backend for later specs.
    local descriptor = { id = "spec_only_backend" }
    assert.equals(CliAdapter.define(descriptor), CliAdapter.define({ id = "spec_only_backend" }))
  end)

  it("is the class behind every compatibility shim", function()
    -- `factory.create` goes through the descriptor and the shims go through `define`; a test or
    -- a user holding either must get instances of the same class.
    for _, def in ipairs(Agents.list()) do
      local via_shim = require(def.adapter_module)
      assert.equals(via_shim, CliAdapter.for_agent(def.id), def.id .. " shim and descriptor classes differ")
    end
  end)

  it("names the instance <id>_cli, which is what limit-state scoping keys on", function()
    for _, def in ipairs(Agents.list()) do
      local adapter = CliAdapter.for_agent(def.id):new({})
      assert.equals(def.id .. "_cli", adapter.name)
      assert.equals(def.id, require("vibing.infrastructure.adapter.factory").agent_id(adapter))
    end
  end)

  it("answers supports() from the descriptor's feature table", function()
    for _, def in ipairs(Agents.list()) do
      local descriptor = require(def.descriptor_module)
      local adapter = CliAdapter.for_agent(def.id):new({})
      for feature, expected in pairs(descriptor.features) do
        assert.equals(expected, adapter:supports(feature), def.id .. " disagrees on " .. feature)
      end
      assert.is_false(adapter:supports("nonexistent_feature"))
    end
  end)

  it("refuses a descriptor with no id", function()
    assert.has_error(function()
      CliAdapter.define({})
    end)
  end)
end)
