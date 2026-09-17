--- Hook settings generator
--- Writes hook settings to .vibing/hook-settings-<instance>.json for --settings flag
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
--- Derived from `permissions.approval_wait_sec`, so the ordering is a property of the derivation
--- rather than of three literals that happen to be in order today.
---
--- What this transport registers as its PreToolUse timeout, or nil if it registers none. Every
--- transport answers this so the ordering invariant can be checked per backend from one place
--- instead of re-deriving each generator's own schema (claude's `timeout`, copilot's `timeoutSec`,
--- codex's `-c` fragment). `hooks/transports.lua` dispatches to it.
--- @return number|nil seconds
function M.hook_timeout_sec()
  return require("vibing.infrastructure.hooks.wait_budget").cli_timeout_sec()
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

--- Where this Neovim's hook settings for a given cwd live.
---
--- **Keyed by instance, and that is a correctness property.** The timeout in this file is derived
--- from `permissions.approval_wait_sec`, while the script's own deadline reaches the CLI child in
--- its environment and is fixed at spawn. One shared path means a second Neovim with a lower
--- `approval_wait_sec` rewrites a file our already-running CLI may re-read, putting the CLI's
--- deadline *ahead* of the script's — the one ordering under which every CLI measured fails open
--- and runs the tool ungated.
---
--- Whether a CLI re-reads its settings per turn is unmeasured, and four backends' worth of
--- unmeasured. A per-instance name means the question never arises. `rpc/instance_key.lua`.
--- @param cwd string
--- @return string
function M.settings_path(cwd)
  return string.format(
    "%s/.vibing/hook-settings-%s.json",
    cwd,
    require("vibing.infrastructure.rpc.instance_key").get()
  )
end

--- Delete hook settings left behind by Neovims that are no longer running.
--- @param vibing_dir string
local function sweep_dead_instances(vibing_dir)
  local InstanceKey = require("vibing.infrastructure.rpc.instance_key")
  InstanceKey.sweep(vibing_dir, "^hook%-settings%-(" .. InstanceKey.PATTERN .. ")%.json$", os.remove)
end

--- Ensure hook settings file exists in .vibing/ of the given cwd
--- @param cwd? string Working directory (defaults to vim.fn.getcwd())
--- @param dialect? string see `generate`
--- @return string path Absolute path to settings file
function M.ensure(cwd, dialect)
  cwd = cwd or vim.fn.getcwd()
  local vibing_dir = cwd .. "/.vibing"
  local settings_path = M.settings_path(cwd)

  Fs.ensure_dir(vibing_dir)
  sweep_dead_instances(vibing_dir)

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
