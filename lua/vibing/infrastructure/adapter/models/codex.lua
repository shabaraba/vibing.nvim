--- Which models the Codex CLI would accept, asked of the CLI and spending no tokens.
---
--- `codex debug models` renders the CLI's own catalogue as JSON. Measured against codex-cli
--- 0.157.1: 9 entries in 20ms, read from the binary's local catalogue -- no network round trip, no
--- API call, so it costs nothing and answers while logged out.
---
--- The catalogue carries no alias field and codex resolves no short name: `-m luna` is handled as
--- an unknown model (`warning: Model metadata for 'luna' not found`, then the request is rejected
--- with "The 'luna' model is not supported"), so the slug is the only thing worth completing.
--- @module vibing.infrastructure.adapter.models.codex

local CodexCommandBuilder = require("vibing.infrastructure.adapter.modules.codex_command_builder")

local M = {}

--- @return string[]
function M.command()
  -- The binary's name rather than `request_builder`'s resolved path: `vim.system` searches PATH
  -- itself, and the resolver raises when the CLI is absent -- which is the ordinary state of a
  -- backend this user does not use, not an error worth surfacing from a completion popup.
  return { CodexCommandBuilder.BINARY.name, "debug", "models" }
end

--- @param stdout string
--- @return Vibing.AgentModelCandidate[]
function M.parse(stdout)
  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok or type(decoded) ~= "table" or type(decoded.models) ~= "table" then
    return {}
  end

  local candidates = {}
  for _, model in ipairs(decoded.models) do
    -- `visibility` is the CLI's own answer to "would `/model` offer this": `hide` covers the
    -- internal engines (`gpt-reserve`, `codex-auto-review`), which are not a user's choice.
    if type(model) == "table" and type(model.slug) == "string" and model.visibility == "list" then
      local description = model.description
      if type(description) ~= "string" then
        description = type(model.display_name) == "string" and model.display_name or model.slug
      end
      table.insert(candidates, { value = model.slug, description = description })
    end
  end

  return candidates
end

return M
