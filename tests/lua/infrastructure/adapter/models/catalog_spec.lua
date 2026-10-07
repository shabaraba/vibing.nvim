---@diagnostic disable: undefined-field
--- What the `model:` completion offers: the backend's own list until its CLI has answered, the
--- CLI's answer afterwards, and the backend's own list again whenever asking fails.
local ModelCatalog = require("vibing.infrastructure.adapter.models.catalog")
local Agents = require("vibing.core.constants.agents")

local CODEX_STDOUT = vim.json.encode({
  models = { { slug = "gpt-7-nova", display_name = "GPT-7-Nova", visibility = "list" } },
})

describe("model catalog", function()
  local spawned
  local response
  local original_system
  local original_executable

  --- Give the probe's callback its turn on the loop. The stubbed `vim.system` calls `on_exit`
  --- itself, so the only wait owed is the `vim.schedule_wrap` one tick.
  local function flush()
    vim.wait(100)
  end

  --- @return string[] the values `model:` would be completed with for this backend
  local function offered(agent)
    return vim.tbl_map(function(candidate)
      return candidate.value
    end, ModelCatalog.candidates_for(agent))
  end

  --- @return string[] the values `agents.lua` falls back to for this backend
  local function fallback(agent)
    local values = vim.tbl_map(function(candidate)
      return candidate.value
    end, Agents.models_for(agent))
    if agent == "codex" then
      table.insert(values, 1, "default")
    end
    return values
  end

  before_each(function()
    ModelCatalog.clear_cache()
    spawned = {}
    response = { code = 0, stdout = CODEX_STDOUT }
    original_system = vim.system
    original_executable = vim.fn.executable
    vim.fn.executable = function()
      return 1
    end
    vim.system = function(argv, _, on_exit)
      table.insert(spawned, argv)
      on_exit(response)
      return { pid = 0 }
    end
  end)

  after_each(function()
    vim.system = original_system
    vim.fn.executable = original_executable
    ModelCatalog.clear_cache()
  end)

  it("asks the backend's own discovery command", function()
    ModelCatalog.candidates_for("codex")
    assert.are.same({ "codex", "debug", "models" }, spawned[1])
  end)

  it("keeps backend-specific default out of the shared model list", function()
    assert.is_true(vim.tbl_contains(offered("codex"), "default"))
    assert.is_false(vim.tbl_contains(ModelCatalog.all_values(), "default"))
  end)

  it("offers agents.lua's list until the CLI has answered, then the CLI's own", function()
    assert.are.same(fallback("codex"), offered("codex"))

    flush()
    assert.are.same({ "default", "gpt-7-nova" }, offered("codex"))
  end)

  it("asks once and answers from what it was told after that", function()
    ModelCatalog.candidates_for("codex")
    flush()

    local asked = #spawned
    ModelCatalog.candidates_for("codex")
    ModelCatalog.candidates_for("codex")
    assert.are.equal(asked, #spawned)
  end)

  it("discovers every backend that has a way of being asked, not only codex", function()
    response = { code = 0, stdout = "Available models:\n  * grok-9.9 (default)\n" }
    ModelCatalog.candidates_for("grok")
    flush()

    assert.are.same({ "grok-9.9" }, offered("grok"))
    assert.are.same({ "grok", "models" }, spawned[1])
  end)

  it("never asks a backend that has no way of being asked", function()
    assert.are.same(fallback("claude"), offered("claude"))
    assert.are.same(fallback("copilot"), offered("copilot"))
    assert.are.same(fallback("claude"), offered("nonexistent"))
    assert.are.equal(0, #spawned)
  end)

  it("never asks a CLI that is not installed", function()
    vim.fn.executable = function()
      return 0
    end
    assert.are.same(fallback("codex"), offered("codex"))
    assert.are.equal(0, #spawned)
  end)

  it("keeps the fallback when the CLI fails, and does not respawn it per keystroke", function()
    response = { code = 1, stdout = "" }
    ModelCatalog.candidates_for("codex")
    flush()

    assert.are.same(fallback("codex"), offered("codex"))
    assert.are.equal(1, #spawned)
  end)

  it("treats an empty catalogue as a failure rather than caching 'this backend has no models'", function()
    response = { code = 0, stdout = vim.json.encode({ models = {} }) }
    ModelCatalog.candidates_for("codex")
    flush()

    assert.are.same(fallback("codex"), offered("codex"))
  end)

  it("asks again after the caches are cleared", function()
    ModelCatalog.candidates_for("codex")
    flush()

    ModelCatalog.clear_cache()
    assert.are.same(fallback("codex"), offered("codex"))
    assert.are.equal(2, #spawned)
  end)
end)
