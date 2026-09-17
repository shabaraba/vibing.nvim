--- How a PreToolUse hook reaches each CLI, selected by name from a backend descriptor.
---
--- The RPC protocol behind the hook is one script (`bin/hooks/pre-tool-use.sh`) and one handler
--- (`rpc/handlers/permission.lua`); what differs per CLI is only how that script is *registered*
--- for one run, and how the script has to phrase its decision. ADR 009 calls those the
--- `transport` and the `dialect`, and a descriptor picks one of each:
---
---   hook = { transport = "config_override", dialect = "claude", keep_in_bypass = true }
---
--- Each transport is one of the settings generators in this directory. They stay separate modules
--- because each carries the measurements that make it work on its CLI (codex hangs on a script
--- outside the writable roots; copilot rejects a matcher; grok wants a trusted git repository);
--- this file is only the seam that lets a descriptor name one without requiring it.
--- @module vibing.infrastructure.hooks.transports

local M = {}

---@class Vibing.HookSpec
---@field transport "settings_file"|"config_override"|"plugin_dir"|"project_dir"
---@field dialect? "claude"|"copilot" How the script phrases a decision; `pre-tool-use.sh`'s first
---  argument. Defaults to `claude`, which the other CLIs sharing its hook schema also read.
---@field keep_in_bypass? boolean Register the hook in bypassPermissions too. The permission handler
---  allows every call in that mode, but the same round trip takes the git-snapshot baseline, so a
---  backend that drops the hook there also loses `### Modified Files` and `gd`.

--- Every transport, in the order the ADR lists them.
--- @type string[]
M.NAMES = { "settings_file", "config_override", "plugin_dir", "project_dir" }

--- Every dialect `bin/hooks/pre-tool-use.sh` knows how to speak. Adding one means adding a
--- `case` branch to that script; the conformance spec checks the two agree.
--- @type table<string, boolean>
M.DIALECTS = { claude = true, copilot = true }

--- Required at call time rather than captured: specs stub a generator's `ensure` on the module
--- table, and a reference taken here would bypass the stub.
local installers = {
  --- `.vibing/hook-settings.json`, handed over with `--settings`. Returns the settings path.
  settings_file = function(cwd, dialect)
    return require("vibing.infrastructure.hooks.settings_generator").ensure(cwd, dialect)
  end,
  --- A `-c hooks.PreToolUse=[…]` override plus the trust bypass, with the script staged inside the
  --- cwd. Returns the argv fragment.
  config_override = function(cwd, dialect)
    return require("vibing.infrastructure.hooks.codex_settings_generator").get_hook_args(cwd, dialect)
  end,
  --- A throwaway plugin under `.vibing/`, loaded with `--plugin-dir`. Returns the plugin directory.
  plugin_dir = function(cwd, dialect)
    return require("vibing.infrastructure.hooks.copilot_settings_generator").ensure(cwd, dialect)
  end,
  --- A hook file the CLI discovers from the project tree. Returns the file it wrote; the argv
  --- does not reference it.
  project_dir = function(cwd, dialect)
    return require("vibing.infrastructure.hooks.grok_settings_generator").ensure(cwd, dialect)
  end,
}

--- The PreToolUse timeout a transport registers, in seconds, or nil if it registers none.
---
--- The hook blocking until a human answers an approval (#778) only stays safe while
--- `permissions.approval_wait_sec < pre-tool-use.sh MAX_WAIT < this`, and the last inequality is
--- load-bearing: **both CLIs measured fail open past their own hook timeout**, running the tool
--- with no verdict at all. That was checked for copilot alone, which is how claude came to ship a
--- timeout exactly equal to the script's own deadline. Asking the transport keeps the check
--- schema-agnostic — each generator knows its own key, and a new one that answers nil is reported
--- rather than skipped.
--- @param hook Vibing.HookSpec
--- @return number|nil seconds
function M.hook_timeout_sec(hook)
  local modules = {
    settings_file = "vibing.infrastructure.hooks.settings_generator",
    config_override = "vibing.infrastructure.hooks.codex_settings_generator",
    plugin_dir = "vibing.infrastructure.hooks.copilot_settings_generator",
    project_dir = "vibing.infrastructure.hooks.grok_settings_generator",
  }
  local module_name = modules[hook and hook.transport]
  if not module_name then
    return nil
  end
  local generator = require(module_name)
  if type(generator.hook_timeout_sec) ~= "function" then
    return nil
  end
  return generator.hook_timeout_sec()
end

--- Register the hook for one run.
--- @param hook Vibing.HookSpec
--- @param cwd string
--- @return any what the command builder needs to reference the hook, if anything
function M.install(hook, cwd)
  local installer = installers[hook.transport]
  if not installer then
    error(string.format("unknown hook transport %q", tostring(hook.transport)), 0)
  end
  local dialect = hook.dialect or "claude"
  if not M.DIALECTS[dialect] then
    error(string.format("unknown hook dialect %q", tostring(dialect)), 0)
  end
  return installer(cwd, dialect)
end

--- Whether this turn registers the hook at all.
---
--- A lightweight call never does (`core/types.lua`: no hooks for utility calls, and routing a
--- title-generation tool call into the chat's approval UI would prompt the user about a request
--- they never made). bypassPermissions registers it only when the backend says the baseline is
--- worth keeping.
--- @param hook Vibing.HookSpec
--- @param opts Vibing.AdapterOpts
--- @return boolean
function M.wanted(hook, opts)
  if opts.lightweight then
    return false
  end
  if (opts.permission_mode or "default") == "bypassPermissions" then
    return hook.keep_in_bypass == true
  end
  return true
end

return M
