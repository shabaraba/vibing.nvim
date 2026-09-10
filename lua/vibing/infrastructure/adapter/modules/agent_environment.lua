--- User-declared environment variables for the CLI child process.
---
--- Claude Code exposes several cost-related knobs only through the environment
--- (`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`, `BASH_MAX_OUTPUT_LENGTH`, `CLAUDE_CODE_SUBAGENT_MODEL`, …).
--- Exporting them from `init.lua` reaches the child too, but it also reaches every other `claude`
--- on the machine and cannot vary per chat. `agent.env` and the chat's `env:` frontmatter are the
--- two scoped ways in; this module is the single place that decides what they may write.
--- @module vibing.infrastructure.adapter.modules.agent_environment

local Notify = require("vibing.core.utils.notify")

local M = {}

--- Reported once per key rather than per turn: the sources are a `setup()` table and a chat's
--- frontmatter, so a bad key is static and would otherwise warn on every request.
local warned = {}

local function warn_once(key, message)
  if warned[key] then
    return
  end
  warned[key] = true
  Notify.warn(message)
end

--- Variables vibing.nvim owns in the child environment.
---
--- `CLAUDECODE` is unset so a nested invocation is possible at all, and the `VIBING_*` family
--- carries the RPC port and the handle ID that tie the child back to this Neovim and this chat
--- buffer. Letting a config value write either would break the hook round trip — the permission
--- gate, the diff baseline and the approval UI all ride on it — so they are refused rather than
--- merged.
--- @param key string
--- @return boolean
function M.is_reserved(key)
  return key == "CLAUDECODE" or key:match("^VIBING_") ~= nil
end

--- Normalize one value to the string `vim.system` expects.
--- @param key string
--- @param value any
--- @return string?
local function normalize(key, value)
  local kind = type(value)
  if kind == "string" then
    return value
  end
  if kind == "number" then
    return tostring(value)
  end
  -- A boolean or a table has no single obvious spelling in an environment ("true"? "1"?), and
  -- guessing one would set a variable the user did not write.
  warn_once(key, string.format("agent.env.%s: expected a string or a number, got %s. Ignored.", key, kind))
  return nil
end

--- Read the frontmatter form, a list of `KEY=VALUE` strings.
---
--- A list rather than a nested map because the chat frontmatter parser is flat by design
--- (`infrastructure/storage/frontmatter.lua`): it understands scalars and block lists, and an
--- indented `key: value` under `env:` is silently dropped. `KEY=VALUE` is the shape `env(1)` uses
--- and the shape the existing list fields already round-trip.
--- @param value any the raw `env` frontmatter value
--- @return table<string, string>
function M.parse_entries(value)
  local out = {}
  for _, entry in ipairs(require("vibing.infrastructure.storage.frontmatter").as_list(value)) do
    local text = tostring(entry)
    local key, raw = text:match("^%s*([%w_]+)%s*=(.*)$")
    if key then
      out[key] = vim.trim(raw)
    else
      -- Namespaced, so a malformed entry spelled like a variable name does not silence the
      -- reserved-key warning for that name, or the other way round.
      warn_once(
        "entry:" .. text,
        string.format("Invalid env frontmatter entry '%s': expected KEY=VALUE. Ignored.", text)
      )
    end
  end
  return out
end

--- Merge `agent.env` and the chat's `env:` frontmatter into a child environment, in place.
---
--- Applied before `RpcEnvironment.bind` and the `CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS` default so
--- that a declared variable behaves exactly like one the user exported: vibing.nvim's own
--- variables still win, and a variable with its own config knob still reads "already set, leave it
--- alone".
--- @param env table<string, string> the child environment, mutated
--- @param config Vibing.Config?
--- @param opts Vibing.AdapterOpts?
function M.apply(env, config, opts)
  opts = opts or {}
  -- A lightweight utility call runs with no tools and no resumed session, so every variable this
  -- feature is for (autocompaction, Bash output length, the subagent model) has nothing to act on.
  if opts.lightweight then
    return
  end

  local declared = {}
  local from_config = config and config.agent and config.agent.env
  if type(from_config) == "table" then
    for key, value in pairs(from_config) do
      declared[key] = value
    end
  end
  -- The chat's own frontmatter is the narrower scope, so it wins over `setup()`.
  for key, value in pairs(M.parse_entries(opts.env)) do
    declared[key] = value
  end

  for key, value in pairs(declared) do
    if M.is_reserved(key) then
      warn_once(key, string.format("%s is set by vibing.nvim and cannot be overridden by env. Ignored.", key))
    else
      local normalized = normalize(key, value)
      if normalized then
        env[key] = normalized
      end
    end
  end
end

--- Forget which keys have already been warned about. Test seam.
function M._reset_warnings()
  warned = {}
end

return M
