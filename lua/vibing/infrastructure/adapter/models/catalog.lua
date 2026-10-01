--- The `model:` candidates a backend would actually accept, asked of its CLI.
---
--- `agents.lua`'s `models` lists are the fallback, not the answer: a CLI ships new models between
--- vibing.nvim releases, so a hand-written list goes stale by construction -- it offered two codex
--- models that no longer exist while missing `gpt-6-sol`, and one grok model that was gone.
---
--- Only a backend that can be *asked* has a `discovery_module`. claude is not one and needs no
--- one: `--model` takes an alias (`opus`, `sonnet`, `fable`) that the CLI itself resolves to the
--- latest model of that family, so the four aliases are the whole answer. The copilot CLI offers
--- no equivalent of `codex debug models` at all.
--- @module vibing.infrastructure.adapter.models.catalog

local Agents = require("vibing.core.constants.agents")

local M = {}

--- What a backend's `discovery_module` exports. Pinned for every registered backend by
--- `tests/lua/infrastructure/adapter/models/discovery_spec.lua`, because a path that does not
--- resolve to this shape would otherwise degrade to the fallback list without saying so.
--- @class Vibing.ModelDiscovery
--- @field command fun(config: Vibing.Config|nil): string[] the argv that lists the CLI's models
--- @field parse fun(stdout: string): Vibing.AgentModelCandidate[] empty when unrecognised

--- @type table<string, Vibing.AgentModelCandidate[]>
local discovered = {}

--- Loop time (ms) before which a backend must not be probed again. Nothing is cached when a probe
--- fails, and `candidates_for` is on the completion path, so without this a CLI that answers
--- wrongly would have one process spawned per keystroke. Same shape and reason as
--- `completion/providers/skills.lua`'s cooldown.
--- @type table<string, number>
local retry_after = {}

--- @type table<string, boolean>
local in_flight = {}

--- @type integer
local FAILURE_COOLDOWN_MS = 30000

--- Long enough for a cold start of the CLI on a busy machine (measured: 20ms for codex, 660ms for
--- grok); short enough that one that never answers does not pin the probe for the session.
--- @type integer
local TIMEOUT_MS = 10000

--- @param id string
--- @return Vibing.ModelDiscovery|nil nil when this backend's CLI cannot be asked
local function discovery_spec(id)
  local path = Agents.get(id).discovery_module
  return path and require(path) or nil
end

--- @param id string
local function probe(id)
  if discovered[id] or in_flight[id] or vim.uv.now() < (retry_after[id] or 0) then
    return
  end

  local spec = discovery_spec(id)
  if not spec then
    return
  end

  local argv = spec.command(require("vibing.config").get())
  -- A backend whose CLI is not installed is the ordinary case, not a failure to report: it is
  -- also the case `vim.system` raises on rather than reporting through the callback.
  if vim.fn.executable(argv[1]) ~= 1 then
    retry_after[id] = vim.uv.now() + FAILURE_COOLDOWN_MS
    return
  end

  in_flight[id] = true
  vim.system(
    argv,
    { text = true, timeout = TIMEOUT_MS },
    vim.schedule_wrap(function(result)
      in_flight[id] = nil

      local candidates = spec.parse(result.stdout or "")
      if result.code ~= 0 or #candidates == 0 then
        -- An empty answer is a failed one -- which is also how a parser reports output it did not
        -- recognise. Caching it would replace the fallback list with nothing, which reads in the
        -- popup as "this backend has no models".
        retry_after[id] = vim.uv.now() + FAILURE_COOLDOWN_MS
        return
      end

      discovered[id] = candidates
    end)
  )
end

--- The model candidates to offer for a backend.
---
--- Synchronous by contract -- both the omnifunc path (`sources/frontmatter.get_candidates_sync`)
--- and the frontmatter cycler call it -- so it answers from what has already been discovered and
--- starts the probe for next time. The first popup of a session shows `agents.lua`'s list; every
--- later one shows the CLI's own.
--- @param agent string? backend id; an unknown one resolves the same way `Agents.get` resolves it
--- @return Vibing.AgentModelCandidate[]
function M.candidates_for(agent)
  local id = Agents.get(agent).id
  probe(id)
  return discovered[id] or Agents.models_for(id)
end

--- Every backend's candidates, in backend order, de-duplicated.
---
--- `/model` **validates** against this as well as completing from it (`handlers/model.lua`), so a
--- list that has gone stale does not merely hide a model the CLI has -- it refuses one the CLI
--- would have accepted. That is why this lives here rather than staying `Agents.all_model_values`.
--- @return string[]
function M.all_values()
  local values = {}
  local seen = {}

  for _, definition in ipairs(Agents.list()) do
    for _, candidate in ipairs(M.candidates_for(definition.id)) do
      if not seen[candidate.value] then
        seen[candidate.value] = true
        table.insert(values, candidate.value)
      end
    end
  end

  return values
end

--- Forget every probed list, so the next call asks the CLIs again. `:VibingReloadCommands`, which
--- is the user asking for a refresh now, cooldown or not.
function M.clear_cache()
  discovered = {}
  retry_after = {}
  in_flight = {}
end

return M
