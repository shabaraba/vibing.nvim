--- Hook settings generator
--- Writes hook settings to .vibing/hook-settings.json for --settings flag
--- @module vibing.infrastructure.hooks.settings_generator

local Fs = require("vibing.core.utils.fs")

local M = {}

--- The PreToolUse timeout this generator registers, in seconds.
---
--- Read by claude and, through `generate()`, by grok. It shipped as **120, the same number as
--- `pre-tool-use.sh`'s own MAX_WAIT** — equal, with no margin at all, where copilot's and codex's
--- generators had both already given themselves 300 for the stated reason that whichever side
--- gives up first decides.
---
--- That equality is a live bug, not a #778 one. Measured against claude 2.1.236 and copilot 1.0.85
--- (`handbook/architecture/approval-without-kill.md` → "What expiry does"): when the **CLI's** hook
--- timeout expires the tool runs with **no verdict at all** — fail open — where the script's own
--- expiry exits 2 and fails closed. So the two deadlines racing at the same number means a slow
--- permission check lands on whichever side the scheduler picks, and half the time that is an
--- ungated tool call. The script's deny has to be the one that arrives.
---
--- Held as a literal here only until `permissions.approval_wait_sec` derives all three numbers
--- (`wait_budget.lua`); what this constant is *for* is the ordering, which
--- `hook_timeout_ordering_spec.lua` now asserts for every registered backend rather than for
--- copilot alone.
local HOOK_TIMEOUT_SEC = 300

--- What this transport registers as its PreToolUse timeout, or nil if it registers none.
---
--- Every transport answers this so the ordering invariant can be checked per backend from one
--- place instead of re-deriving each generator's own schema (claude's `timeout`, copilot's
--- `timeoutSec`, codex's `-c` fragment). `hooks/transports.lua` dispatches to it.
--- @return number|nil seconds
function M.hook_timeout_sec()
  return HOOK_TIMEOUT_SEC
end

--- Resolve a bundled hook script by file name
--- @param name string File name under bin/hooks/
--- @return string
local function hook_script_path(name)
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fn.fnamemodify(source, ":h:h:h:h:h")
  return plugin_root .. "/bin/hooks/" .. name
end

--- Get the path to the PreToolUse hook script
--- @return string
function M.get_hook_script_path()
  return hook_script_path("pre-tool-use.sh")
end

--- Get the path to the StopFailure hook script
--- @return string
function M.get_stop_failure_script_path()
  return hook_script_path("stop-failure.sh")
end

--- The command line that runs the PreToolUse script in a given dialect.
---
--- `claude` is the script's default and is passed as nothing, so the settings a claude user has
--- seen so far are byte-identical; any other dialect travels as the script's first argument.
--- @param script string absolute script path
--- @param dialect? string
--- @return string
function M.hook_command(script, dialect)
  if dialect and dialect ~= "claude" then
    return script .. " " .. dialect
  end
  return script
end

--- Generate settings table with hook configuration
--- @param hook_script_path? string Override for the PreToolUse script path. Grok resolves a
---   relative hook command against its own .grok/hooks/ file rather than the project root, so it
---   has to pass an absolute path it computed itself.
--- @param dialect? string how the script should phrase its decision (`hooks/transports.lua`)
--- @return table
function M.generate(hook_script_path, dialect)
  local pre_tool_use_script = M.hook_command(hook_script_path or M.get_hook_script_path(), dialect)

  return {
    hooks = {
      PreToolUse = {
        {
          matcher = ".*",
          hooks = {
            {
              type = "command",
              command = pre_tool_use_script,
              timeout = M.hook_timeout_sec(),
            },
          },
        },
      },
      -- StopFailure fires when a turn dies from an API error. The matcher filters on error type,
      -- and only rate_limit is actionable — the rest (overloaded, billing_error, ...) have no
      -- reset time to wait for. The hook cannot block or alter anything; it exists purely so the
      -- auto-resume scheduler learns the turn died rather than completed.
      StopFailure = {
        {
          matcher = "rate_limit",
          hooks = {
            {
              type = "command",
              command = M.get_stop_failure_script_path(),
              timeout = 10,
            },
          },
        },
      },
    },
  }
end

--- Ensure hook settings file exists in .vibing/ of the given cwd
--- @param cwd? string Working directory (defaults to vim.fn.getcwd())
--- @param dialect? string see `generate`
--- @return string path Absolute path to settings file
function M.ensure(cwd, dialect)
  cwd = cwd or vim.fn.getcwd()
  local vibing_dir = cwd .. "/.vibing"
  local settings_path = vibing_dir .. "/hook-settings.json"

  Fs.ensure_dir(vibing_dir)

  -- Always regenerate (hook script path may change after plugin update)
  local settings = M.generate(nil, dialect)
  local json = vim.json.encode(settings)

  local f = io.open(settings_path, "w")
  if not f then
    error("Failed to create hook settings file: " .. settings_path)
  end
  f:write(json)
  f:close()

  return settings_path
end

return M
