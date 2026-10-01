---@diagnostic disable: undefined-field
--- The two per-backend model-discovery modules: what the CLI prints, turned into candidates.
--- Both parsers are pure, so the real output of each CLI is pinned here as a fixture.
local Codex = require("vibing.infrastructure.adapter.models.codex")
local Grok = require("vibing.infrastructure.adapter.models.grok")

--- Trimmed from `codex debug models` (codex-cli 0.157.1): one listed entry with a description, one
--- with none, and one the CLI hides.
local CODEX_STDOUT = vim.json.encode({
  models = {
    {
      slug = "gpt-6-astra",
      display_name = "GPT-6-Astra",
      description = "Frontier intelligence for the most demanding work.",
      visibility = "list",
    },
    { slug = "gpt-6-luna", display_name = "GPT-6-Luna", visibility = "list" },
    { slug = "gpt-reserve", display_name = "GPT-Reserve", description = "internal", visibility = "hide" },
  },
})

--- `grok models` (grok 1.0.34), including the unauthenticated banner it prints above the list.
local GROK_STDOUT = table.concat({
  "You are not authenticated.",
  "",
  "Default model: grok-4.6",
  "",
  "Available models:",
  "  * grok-4.6 (default)",
  "  - grok-4.5",
  "",
}, "\n")

local function values(candidates)
  return vim.tbl_map(function(candidate)
    return candidate.value
  end, candidates)
end

describe("codex model discovery", function()
  it("asks the CLI for its own catalogue", function()
    assert.are.same({ "codex", "debug", "models" }, Codex.command())
  end)

  it("offers the listed slugs and drops the hidden ones", function()
    assert.are.same({ "gpt-6-astra", "gpt-6-luna" }, values(Codex.parse(CODEX_STDOUT)))
  end)

  it("describes a model with the CLI's own description, falling back to its display name", function()
    local candidates = Codex.parse(CODEX_STDOUT)
    assert.are.equal("Frontier intelligence for the most demanding work.", candidates[1].description)
    assert.are.equal("GPT-6-Luna", candidates[2].description)
  end)

  it("answers with no candidates rather than raising on output that is not the catalogue", function()
    assert.are.same({}, Codex.parse("not json at all"))
    assert.are.same({}, Codex.parse(vim.json.encode({ models = "nonsense" })))
  end)
end)

describe("grok model discovery", function()
  it("looks the CLI up on PATH by default", function()
    assert.are.same({ "grok", "models" }, Grok.command({}))
    assert.are.same({ "grok", "models" }, Grok.command({ backends = { grok = { executable = "auto" } } }))
  end)

  it("uses the configured executable when there is one", function()
    assert.are.same({ "/opt/grok", "models" }, Grok.command({ backends = { grok = { executable = "/opt/grok" } } }))
  end)

  it("reads the bulleted entries and not the 'Default model:' line", function()
    assert.are.same({ "grok-4.6", "grok-4.5" }, values(Grok.parse(GROK_STDOUT)))
  end)

  it("marks the default model, the one thing the CLI says about any of them", function()
    local candidates = Grok.parse(GROK_STDOUT)
    assert.are.equal("Grok CLI default model", candidates[1].description)
    assert.are.equal("Available in the Grok CLI", candidates[2].description)
  end)

  it("answers with no candidates when the CLI printed no list", function()
    assert.are.same({}, Grok.parse("You are not authenticated.\n"))
  end)
end)
