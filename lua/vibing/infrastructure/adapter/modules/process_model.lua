--- Which process model one turn runs under: a process per turn, or a resident one (#777).
---
--- `descriptor.process` names the **most capable** model a backend can run, not the one it will:
--- the default stays `oneshot` for every backend, and `duplex` is reached only when a chat asks for
--- it. Expressing capability rather than default is what lets a single descriptor field carry both
--- halves — a backend whose CLI cannot read a prompt from stdin says nothing, and no amount of
--- configuration can then hand it one.
---
--- The field is deliberately not called `transport`: `hooks/transports.lua` already owns that word
--- for `Vibing.HookSpec.transport`, and two unrelated "transport"s in one descriptor is how a
--- conformance branch ends up testing the wrong one.
--- @module vibing.infrastructure.adapter.modules.process_model

local Notify = require("vibing.core.utils.notify")

local M = {}

M.ONESHOT = "oneshot"
M.DUPLEX = "duplex"

--- @type table<string, boolean>
local VALID = { [M.ONESHOT] = true, [M.DUPLEX] = true }

--- Whether a value names a process model at all.
--- @param value any
--- @return boolean
local function is_valid(value)
  return VALID[value] == true
end

--- Say once that a chat asked for `duplex` and is not getting it.
---
--- A refusal that shows in the argv is a refusal the reader can find; these show nowhere at all.
--- Someone who writes `backends.grok.process = "duplex"`, or mistypes the value, gets a chat that
--- behaves exactly as before and no way to learn why — `config.lua`'s validation walks only
--- *declared* fields, so an undeclared `process` on another backend is not even rejected there.
--- They would then measure the thing they think they turned on. Same shape as an unrecognised
--- `effort` level, dropped with a warning for the same reason: some CLIs accept it silently and
--- ignore it.
---
--- Keyed rather than plain, because a downgrade is decided on every turn: `warn_once` is the same
--- memo `config.lua` uses for a bad `backends.<id>.<field>`, so a test resets it the same way.
--- @param key string what to announce at most once
--- @param message string
local function announce_downgrade(key, message)
  Notify.warn_once(key, message .. " Running one CLI process per turn instead.")
end

--- What a chat asked for, before the backend's own ceiling is applied.
---
--- Read in the same order every other per-chat override is: the chat's own frontmatter first, then
--- `backends.<id>.process`, then the default. An unrecognised value is dropped with a warning
--- rather than guessed at, because guessing `duplex` from a typo would silently change the process
--- model of every chat on that backend.
--- @param descriptor_id string
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string
local function requested(descriptor_id, opts, config)
  local candidates = {
    { value = opts.process, label = "the chat's `process:` frontmatter" },
    {
      value = vim.tbl_get(config or {}, "backends", descriptor_id, "process"),
      label = string.format("backends.%s.process", descriptor_id),
    },
  }
  for _, candidate in ipairs(candidates) do
    if candidate.value ~= nil then
      if is_valid(candidate.value) then
        return candidate.value
      end
      -- Through the same once-per-key path as every other downgrade: a typo in frontmatter is read
      -- on every single turn, and warning each time trains the reader to ignore the warning.
      announce_downgrade(
        "invalid:" .. candidate.label .. ":" .. tostring(candidate.value),
        string.format("%s is %s, which is not a process model.", candidate.label, vim.inspect(candidate.value))
      )
      return M.ONESHOT
    end
  end
  return M.ONESHOT
end

--- The process model this turn actually runs under.
---
--- Three kinds of turn are held at `oneshot` whatever was asked for, and all three are correctness
--- rather than caution:
---
--- * **A lightweight call** owes the bargain in `core/types.lua` — no tools, no project config, no
---   user MCP servers, no hooks, `utility_model`. A resident process serving a chat has all five,
---   and one process cannot hold both sets at once. Not announced: this is internal machinery
---   (title generation, `/summarize`), not a chat anyone is watching for speed.
--- * **A subagent chat** shares its parent's `session_id` permanently (`chat-lineage.md`). A
---   resident process holds its `--resume` for its whole life, so two of them would sit on one
---   transcript indefinitely — the corruption `process_registry.find_other_holding_session` exists
---   to refuse, made permanent.
--- * **A backend whose descriptor does not declare `duplex`.** The field is a ceiling, and no
---   amount of configuration raises it.
---
--- @param descriptor Vibing.BackendDescriptor
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string one of `M.ONESHOT` / `M.DUPLEX`
function M.resolve(descriptor, opts, config)
  opts = opts or {}
  if requested(descriptor.id, opts, config) == M.ONESHOT then
    return M.ONESHOT
  end

  -- Below here the chat asked for `duplex`, so every exit is a downgrade.
  if opts.lightweight then
    return M.ONESHOT
  end
  if descriptor.process ~= M.DUPLEX then
    announce_downgrade(
      "ceiling:" .. descriptor.id,
      string.format("The %s CLI cannot serve several turns from one process.", descriptor.id)
    )
    return M.ONESHOT
  end
  if opts._subagent_id then
    announce_downgrade(
      "subagent:" .. tostring(opts._subagent_id),
      "A subagent chat shares its parent's session permanently, so it cannot hold a resident process."
    )
    return M.ONESHOT
  end
  -- The pool is keyed by chat because that is what a process serves for its whole life
  -- (`duplex_pool.lua`); a turn with no chat to key on has nowhere to leave the process.
  if not opts.chat_bufnr then
    return M.ONESHOT
  end
  return M.DUPLEX
end

return M
