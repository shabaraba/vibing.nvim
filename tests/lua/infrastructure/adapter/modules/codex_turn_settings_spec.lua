local Settings = require("vibing.infrastructure.adapter.modules.codex_turn_settings")

describe("Codex turn settings", function()
  it("keeps agent defaults for absent chat fields but lets explicit default bypass them", function()
    local config = { agent = { default_model = "gpt-6-sol", default_effort = "high" } }
    assert.same({ model = "gpt-6-sol", effort = "high" }, Settings.resolve({}, config))
    assert.same({}, Settings.resolve({ model = "default", effort = "default" }, config))
  end)

  it("uses the selected model's default effort when no effort override is requested", function()
    local defaults = assert(Settings.defaults(
      { config = { model = vim.NIL, model_reasoning_effort = vim.NIL } },
      { data = {
        { model = "gpt-6.1-sol", isDefault = true, defaultReasoningEffort = "medium" },
        { model = "gpt-6-luna", defaultReasoningEffort = "low" },
      } }
    ))
    assert.same({ model = "gpt-6-luna", effort = "low" }, Settings.for_turn({ model = "gpt-6-luna" }, defaults))
    assert.same({ model = "gpt-6.1-sol", effort = "medium" }, Settings.for_turn({}, defaults))
  end)

  it("allows custom models with explicit effort or no prior effort override", function()
    local defaults = assert(Settings.defaults({ config = { model = "local-model" } }, { data = {} }))
    assert.same({ model = "local-model", effort = "high" }, Settings.for_turn({ effort = "high" }, defaults))
    assert.same({ model = "local-model" }, Settings.for_turn({}, defaults))
    local selection, err = Settings.for_turn({}, defaults, { effort = "high" })
    assert.is_nil(selection)
    assert.matches("set effort explicitly", err)
    assert.is_nil(Settings.for_turn({ model = "another-local-model" }, defaults, { model = "local-model" }))
  end)
end)
