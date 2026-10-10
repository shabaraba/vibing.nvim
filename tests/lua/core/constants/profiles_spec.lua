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
    assert.same({ "default", "focused", "reviewer" }, Profiles.names(nil))
    assert.is_true(Profiles.is_valid("focused", nil))
    assert.is_true(Profiles.is_valid("reviewer", nil))
    assert.is_false(Profiles.is_valid("implementer", nil))
  end)

  it("no longer knows the removed worker profile", function()
    assert.is_false(Profiles.is_valid("worker", nil))

    local name, def = Profiles.resolve("worker", nil)
    assert.equals("default", name)
    assert.is_nil(def.tools)
    assert.equals(1, #warnings)
  end)

  it("narrows focused to six built-in tools plus ToolSearch, keeping the configured sources", function()
    local name, def = Profiles.resolve("focused", nil)

    assert.equals("focused", name)
    assert.same({ "Bash", "Read", "Edit", "Write", "Glob", "Grep", "ToolSearch" }, def.tools)
    assert.is_nil(def.setting_sources)
    assert.is_nil(def.context_files)
    assert.is_nil(def.model)
    assert.is_truthy(def.description)
    assert.equals(0, #warnings)
  end)

  it("narrows reviewer to read-and-run tools plus ToolSearch, keeping the configured sources", function()
    local name, def = Profiles.resolve("reviewer", nil)

    assert.equals("reviewer", name)
    assert.same({ "Read", "Glob", "Grep", "Bash", "ToolSearch" }, def.tools)
    assert.is_nil(def.setting_sources)
    assert.is_nil(def.model)
    assert.is_truthy(def.description)
  end)

  it("leaves default on the CLI's full tool set", function()
    local _, def = Profiles.resolve("default", nil)

    assert.is_nil(def.tools)
    assert.is_nil(def.setting_sources)
  end)

  -- Unknown keys are ignored like any other key a profile does not have; `instructions` is one
  -- now, since the instruction block is the same on every profile.
  it("ignores the removed instructions field, like any unknown key", function()
    local _, def = Profiles.resolve("a", config({ { name = "a", instructions = "worker", model = "haiku" } }))

    assert.is_nil(def.instructions)
    assert.equals("haiku", def.model)
    assert.equals(0, #warnings)
  end)

  it("adds every configured name to the built-ins", function()
    local cfg = config({ { name = "implementer", model = "sonnet" } })

    assert.same({ "default", "focused", "implementer", "reviewer" }, Profiles.names(cfg))
    assert.is_true(Profiles.is_valid("implementer", cfg))
  end)

  it("resolves no profile, and an unknown one, to the full default", function()
    local name, def = Profiles.resolve(nil, nil)
    assert.equals("default", name)
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
    local _, def = Profiles.resolve("a", config({ { name = "a", tools = { "Read", "Edit" } } }))
    assert.same({ "Read", "Edit", "ToolSearch" }, def.tools)

    local _, already = Profiles.resolve("b", config({ { name = "b", tools = { "Read", "ToolSearch" } } }))
    assert.same({ "Read", "ToolSearch" }, already.tools)
  end)

  it("accepts an empty setting_sources list as a deliberate choice", function()
    local _, def = Profiles.resolve("bare", config({ { name = "bare", setting_sources = {} } }))

    assert.same({}, def.setting_sources)
    assert.equals(0, #warnings)
  end)

  -- A field that cannot be used is dropped, never half-applied: a typo has to load more, not less.
  for _, case in ipairs({
    { field = "tools", value = "Read,Edit" },
    { field = "tools", value = { "Read,Edit" } },
    { field = "setting_sources", value = { "project", "global" } },
    { field = "context_files", value = { "a\nb" } },
    { field = "model", value = "" },
  }) do
    it("drops an invalid " .. case.field .. " with a warning", function()
      local _, def = Profiles.resolve("p", config({ { name = "p", [case.field] = case.value } }))

      assert.is_nil(def[case.field])
      assert.equals(1, #warnings)
      assert.is_truthy(warnings[1]:find('agent.profiles[name="p"].' .. case.field, 1, true))
    end)
  end

  it("lets a configured entry extend a built-in field by field", function()
    local _, def = Profiles.resolve("focused", config({ { name = "focused", model = "haiku" } }))

    assert.equals("haiku", def.model)
    assert.same({ "Bash", "Read", "Edit", "Write", "Glob", "Grep", "ToolSearch" }, def.tools)
  end)

  it("lets a configured entry replace a built-in's tool list", function()
    local _, def = Profiles.resolve("reviewer", config({ { name = "reviewer", tools = { "Read" } } }))

    assert.same({ "Read", "ToolSearch" }, def.tools)
    -- the built-in itself is untouched for the next caller
    local _, again = Profiles.resolve("reviewer", nil)
    assert.same({ "Read", "Glob", "Grep", "Bash", "ToolSearch" }, again.tools)
  end)

  it("lists every profile with what a chat created on it runs on", function()
    local catalog = Profiles.catalog(config({ { name = "implementer", description = "Implements", model = "sonnet" } }))

    local by_name = {}
    for _, entry in ipairs(catalog) do
      by_name[entry.name] = entry
    end
    assert.equals("sonnet", by_name.implementer.model)
    assert.equals("Implements", by_name.implementer.description)
    assert.is_not_nil(by_name.default)
    assert.is_not_nil(by_name.focused)
    assert.is_not_nil(by_name.reviewer)
  end)

  it("takes each entry's name from its name field, whatever its position", function()
    local cfg = config({ { name = "zeta", model = "haiku" }, { name = "alpha", model = "sonnet" } })

    assert.same({ "alpha", "default", "focused", "reviewer", "zeta" }, Profiles.names(cfg))
    local name, def = Profiles.resolve("alpha", cfg)
    assert.equals("alpha", name)
    assert.equals("sonnet", def.model)
    assert.equals(0, #warnings)
  end)

  it("does not treat the name field as a profile field", function()
    local _, def = Profiles.resolve("a", config({ { name = "a", model = "haiku" } }))

    assert.is_nil(def.name)
  end)

  it("ignores an entry without a usable name, with a warning", function()
    local cfg = config({ { model = "haiku" }, { name = "", model = "haiku" }, { name = "has space" }, { name = 3 } })

    assert.same({ "default", "focused", "reviewer" }, Profiles.names(cfg))
    assert.equals(4, #warnings)
    assert.is_truthy(warnings[1]:find("agent.profiles[1].name", 1, true))
    assert.is_truthy(warnings[4]:find("agent.profiles[4].name", 1, true))
  end)

  it("ignores an entry that is not a table, with a warning", function()
    local cfg = config({ "implementer", { name = "ok" } })

    assert.same({ "default", "focused", "ok", "reviewer" }, Profiles.names(cfg))
    assert.equals(1, #warnings)
    assert.is_truthy(warnings[1]:find("agent.profiles[1] is not a table", 1, true))
  end)

  it("lets the last of two entries with the same name win, and warns once", function()
    local cfg = config({ { name = "dup", model = "haiku" }, { name = "dup", model = "sonnet" } })

    local _, def = Profiles.resolve("dup", cfg)
    Profiles.resolve("dup", cfg)

    assert.equals("sonnet", def.model)
    assert.same({ "default", "dup", "focused", "reviewer" }, Profiles.names(cfg))
    assert.equals(1, #warnings)
    assert.is_truthy(warnings[1]:find('more than one entry named "dup"', 1, true))
  end)

  -- The keyed form an earlier draft of this feature read. Ignoring it loudly is the safe failure:
  -- the chat loads the full default rather than a half-read profile.
  it("ignores a keyed table, naming the list form", function()
    local cfg = config({ implementer = { model = "sonnet" } })

    assert.same({ "default", "focused", "reviewer" }, Profiles.names(cfg))
    assert.equals(1, #warnings)
    assert.is_truthy(warnings[1]:find('{ { name = "implementer"', 1, true))
  end)
end)
