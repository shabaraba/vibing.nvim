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

  --- Give the probe's callback its turn on the loop; it is `vim.schedule_wrap`ped, so nothing has
  --- happened yet when `candidates_for` returns.
  --- @param predicate fun(): boolean
  local function eventually(predicate)
    return vim.wait(1000, predicate, 10)
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

  it("offers agents.lua's list until the CLI has answered, then the CLI's own", function()
    local before = ModelCatalog.candidates_for("codex")
    assert.are.same(Agents.models_for("codex"), before)

    assert.is_true(eventually(function()
      return ModelCatalog.candidates_for("codex")[1].value == "gpt-7-nova"
    end))
    assert.are.equal(1, #ModelCatalog.candidates_for("codex"))
  end)

  it("asks once and answers from what it was told after that", function()
    ModelCatalog.candidates_for("codex")
    assert.is_true(eventually(function()
      return ModelCatalog.candidates_for("codex")[1].value == "gpt-7-nova"
    end))

    local asked = #spawned
    ModelCatalog.candidates_for("codex")
    ModelCatalog.candidates_for("codex")
    assert.are.equal(asked, #spawned)
  end)

  it("discovers every backend that has a way of being asked, not only codex", function()
    response = { code = 0, stdout = "Available models:\n  * grok-9.9 (default)\n" }
    ModelCatalog.candidates_for("grok")

    assert.is_true(eventually(function()
      return ModelCatalog.candidates_for("grok")[1].value == "grok-9.9"
    end))
    assert.are.same({ "grok", "models" }, spawned[1])
  end)

  it("never asks a backend that has no way of being asked", function()
    assert.are.same(Agents.models_for("claude"), ModelCatalog.candidates_for("claude"))
    assert.are.same(Agents.models_for("copilot"), ModelCatalog.candidates_for("copilot"))
    assert.are.same(Agents.models_for("claude"), ModelCatalog.candidates_for("nonexistent"))
    assert.are.equal(0, #spawned)
  end)

  it("never asks a CLI that is not installed", function()
    vim.fn.executable = function()
      return 0
    end
    assert.are.same(Agents.models_for("codex"), ModelCatalog.candidates_for("codex"))
    assert.are.equal(0, #spawned)
  end)

  it("keeps the fallback when the CLI fails, and does not respawn it per keystroke", function()
    response = { code = 1, stdout = "" }
    ModelCatalog.candidates_for("codex")
    vim.wait(100)

    assert.are.same(Agents.models_for("codex"), ModelCatalog.candidates_for("codex"))
    assert.are.equal(1, #spawned)
  end)

  it("treats an empty catalogue as a failure rather than caching 'this backend has no models'", function()
    response = { code = 0, stdout = vim.json.encode({ models = {} }) }
    ModelCatalog.candidates_for("codex")
    vim.wait(100)

    assert.are.same(Agents.models_for("codex"), ModelCatalog.candidates_for("codex"))
  end)

  it("asks again after the caches are cleared", function()
    ModelCatalog.candidates_for("codex")
    assert.is_true(eventually(function()
      return ModelCatalog.candidates_for("codex")[1].value == "gpt-7-nova"
    end))

    ModelCatalog.clear_cache()
    assert.are.same(Agents.models_for("codex"), ModelCatalog.candidates_for("codex"))
    assert.are.equal(2, #spawned)
  end)
end)
