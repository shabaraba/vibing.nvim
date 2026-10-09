local Profiles = require("vibing.core.constants.profiles")

describe("profiles", function()
  local notify, original_warn, warnings

  before_each(function()
    Profiles._reset_warnings()
    notify = require("vibing.core.utils.notify")
    original_warn = notify.warn
    warnings = {}
    notify.warn = function(message)
      table.insert(warnings, message)
    end
  end)

  after_each(function()
    notify.warn = original_warn
    Profiles._reset_warnings()
  end)

  local function config(profiles)
    return { agent = { profiles = profiles } }
  end

  it("knows the built-ins with no configuration at all", function()
    assert.same({ "default", "worker" }, Profiles.names(nil))
    assert.is_true(Profiles.is_valid("worker", nil))
    assert.is_false(Profiles.is_valid("implementer", nil))
  end)

  it("adds every configured name to the built-ins", function()
    local cfg = config({ implementer = { model = "sonnet" } })

    assert.same({ "default", "implementer", "worker" }, Profiles.names(cfg))
    assert.is_true(Profiles.is_valid("implementer", cfg))
  end)

  it("resolves no profile, and an unknown one, to the full default", function()
    local name, def = Profiles.resolve(nil, nil)
    assert.equals("default", name)
    assert.equals("full", def.instructions)
    assert.is_nil(def.tools)

    local unknown_name, unknown_def = Profiles.resolve("lean", nil)
    assert.equals("default", unknown_name)
    assert.is_nil(unknown_def.tools)
    assert.equals(1, #warnings)
  end)

  it("warns about an unknown profile once, not on every request", function()
    Profiles.resolve("lean", nil)
    Profiles.resolve("lean", nil)

    assert.equals(1, #warnings)
  end)

  -- Without ToolSearch every MCP schema is loaded into the prompt instead of staying deferred
  -- (+14k measured), which would quietly undo most of what narrowing the tools saves.
  it("always adds ToolSearch to a tool list, once", function()
    local _, def = Profiles.resolve("a", config({ a = { tools = { "Read", "Edit" } } }))
    assert.same({ "Read", "Edit", "ToolSearch" }, def.tools)

    local _, already = Profiles.resolve("b", config({ b = { tools = { "Read", "ToolSearch" } } }))
    assert.same({ "Read", "ToolSearch" }, already.tools)
  end)

  it("accepts an empty setting_sources list as a deliberate choice", function()
    local _, def = Profiles.resolve("bare", config({ bare = { setting_sources = {} } }))

    assert.same({}, def.setting_sources)
    assert.equals(0, #warnings)
  end)

  -- A field that cannot be used is dropped, never half-applied: a typo has to load more, not less.
  for _, case in ipairs({
    { field = "tools", value = "Read,Edit" },
    { field = "tools", value = { "Read,Edit" } },
    { field = "setting_sources", value = { "project", "global" } },
    { field = "instructions", value = "minimal" },
    { field = "context_files", value = { "a\nb" } },
    { field = "model", value = "" },
  }) do
    it("drops an invalid " .. case.field .. " with a warning", function()
      local _, def = Profiles.resolve("p", config({ p = { [case.field] = case.value } }))

      if case.field == "instructions" then
        assert.equals("full", def.instructions)
      else
        assert.is_nil(def[case.field])
      end
      assert.equals(1, #warnings)
      assert.is_truthy(warnings[1]:find("agent.profiles.p." .. case.field, 1, true))
    end)
  end

  it("lets a configured worker extend the built-in one", function()
    local _, def = Profiles.resolve("worker", config({ worker = { model = "haiku" } }))

    assert.equals("worker", def.instructions)
    assert.equals("haiku", def.model)
  end)

  it("lists every profile with what a chat created on it runs on", function()
    local catalog = Profiles.catalog(config({ implementer = { description = "Implements", model = "sonnet" } }))

    local by_name = {}
    for _, entry in ipairs(catalog) do
      by_name[entry.name] = entry
    end
    assert.equals("sonnet", by_name.implementer.model)
    assert.equals("Implements", by_name.implementer.description)
    assert.is_not_nil(by_name.default)
    assert.is_not_nil(by_name.worker)
  end)
end)
