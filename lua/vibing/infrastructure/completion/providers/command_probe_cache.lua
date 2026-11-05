--- What each backend's CLI said it can run, per backend and per directory.
---
--- One entry per agent id, because a chat's `agent:` frontmatter can name any backend and two chats
--- can name different ones: a single shared list would offer Claude's `/design` to a Codex chat.
--- Nothing is cached on failure, and `get_all()` is on the completion path, so a CLI that answers
--- wrongly (or not at all) is retried at most once per `FAILURE_COOLDOWN_MS` instead of once per
--- keystroke. `:VibingReloadCommands` skips the cooldown through `clear()`.
--- @module vibing.infrastructure.completion.providers.command_probe_cache

local CommandProbe = require("vibing.infrastructure.completion.command_probe")

local M = {}

local FAILURE_COOLDOWN_MS = 30000

--- @class Vibing.CommandProbeState
--- @field commands Vibing.CliCommand[]? the CLI's answer, once it has given one
--- @field loading boolean
--- @field cwd string? the directory the answer (or the probe in flight) describes
--- @field retry_after number loop time (ms) before which a new probe must not start

--- Replaced, never mutated, on reset: a probe in flight holds the table it started with and
--- compares it against this one, which is what cancels an answer to a question no longer asked.
--- @type table<string, Vibing.CommandProbeState>
local states = {}

--- @param agent string
--- @return Vibing.CommandProbeState
local function state_of(agent)
  if not states[agent] then
    states[agent] = { loading = false, retry_after = 0 }
  end
  return states[agent]
end

--- Plugin directories vibing.nvim self-hosts via `--plugin-dir`. Claude is asked for its command
--- list with the very same flags a chat gets, so their skills are namespaced and reported by the
--- CLI itself rather than being rediscovered here.
---
--- Resolved against the same global cwd the rest of the provider keys on, not a chat's
--- `working_dir`: completion is a property of the editor, not of whichever chat buffer is focused.
--- Passing it explicitly is what lets the cwd stand in as this list's staleness key too:
--- `plugin_dirs` caches per cwd, so with the cwd unchanged the list cannot change underneath us
--- except via `plugin_dirs.clear_cache()`, whose only caller (`:VibingReloadCommands`) clears this
--- module in the same breath.
--- @return string[]
local function resolve_plugin_dirs()
  local ok, PluginDirs = pcall(require, "vibing.infrastructure.plugins.plugin_dirs")
  local config_ok, Config = pcall(require, "vibing.config")
  if not ok or not config_ok then
    return {}
  end
  return PluginDirs.resolve(vim.fn.getcwd(-1, -1), Config.get())
end

--- Drop every answer that describes a directory other than the current one: project skills,
--- project settings and `.vibing/plugins` are all resolved from the cwd.
--- @return boolean dropped whether anything was
function M.invalidate_if_stale()
  local cwd = vim.fn.getcwd(-1, -1)
  local dropped = false
  for agent, state in pairs(states) do
    -- A nil cwd means no probe has been started for this agent, which is not staleness.
    if state.cwd ~= nil and state.cwd ~= cwd then
      states[agent] = nil
      dropped = true
    end
  end
  return dropped
end

--- The CLI's answer for this agent, or nil if it has not given one. Never starts a probe.
--- @param agent string
--- @return Vibing.CliCommand[]?
function M.peek(agent)
  local state = states[agent]
  return state and state.commands or nil
end

--- @param agent string
--- @return boolean
function M.is_loading(agent)
  local state = states[agent]
  return state ~= nil and state.loading
end

--- Start the background probe unless one is running, has answered, or failed a moment ago.
--- @param agent string
--- @param probe Vibing.CommandProbe
--- @param on_loaded fun() called when the CLI answered
function M.start(agent, probe, on_loaded)
  local state = state_of(agent)
  if state.commands or state.loading or vim.uv.now() < state.retry_after then
    return
  end

  local config_ok, Config = pcall(require, "vibing.config")
  local Agents = require("vibing.core.constants.agents")
  if not config_ok or not Agents.is_valid(agent) then
    return
  end
  local descriptor_ok, descriptor = pcall(require, Agents.get(agent).descriptor_module)
  if not descriptor_ok then
    return
  end

  local cwd = vim.fn.getcwd(-1, -1)
  state.loading = true
  state.cwd = cwd

  local started = CommandProbe.fetch(probe, {
    agent = agent,
    descriptor = descriptor,
    cwd = cwd,
    config = Config.get(),
    plugin_dirs = resolve_plugin_dirs(),
  }, function(commands)
    if states[agent] ~= state then
      return
    end
    state.loading = false
    -- Nothing is cached on failure, so a later completion trigger retries. Same for a cwd that
    -- moved while the probe was in flight -- the answer describes the directory it was asked in.
    if not commands or vim.fn.getcwd(-1, -1) ~= cwd then
      state.retry_after = vim.uv.now() + FAILURE_COOLDOWN_MS
      return
    end
    state.commands = commands
    on_loaded()
  end)

  if not started then
    state.loading = false
    state.cwd = nil
    state.retry_after = vim.uv.now() + FAILURE_COOLDOWN_MS
  end
end

--- Forget everything, including cooldowns.
function M.clear()
  states = {}
end

return M
