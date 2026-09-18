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
---@field measured_wait_floor_sec? number The longest this CLI was **measured** to let a PreToolUse
---  hook block without cutting it. A floor, not a ceiling: it says the CLI waited at least this
---  long, not that it would have stopped after. Absent means unmeasured, which is what decides
---  whether an approval may be answered without killing the process — see `can_wait_for_approval`.

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
  --- `.vibing/hook-settings-<instance>.json`, handed over with `--settings`. Returns the settings path.
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

--- Whether an approval on this backend may be answered **without killing the CLI** (#778).
---
--- Waiting means the hook blocks inside the CLI until a human answers, so it is safe only where the
--- CLI has been measured to wait at least that long. Past its own timeout every CLI measured fails
--- **open** — the tool runs with no verdict at all — so a backend that is merely *probably* patient
--- enough is a permission gate that silently stops applying.
---
--- Hence a measured floor rather than a boolean: an opinion is what a boolean records, and the
--- opinion here has been wrong twice (`handbook/architecture/approval-without-kill.md` → "How this
--- was measured wrong twice"). Comparing the floor against the deadline the *current* configuration
--- derives also makes the answer follow `permissions.approval_wait_sec`: raise it past what a CLI
--- was measured to tolerate and that backend falls back on its own, rather than quietly waiting
--- longer than the evidence covers.
---
--- Absent floor → false. A new backend therefore keeps today's kill-and-retry behaviour until
--- somebody runs `tests/perf/hook_wait_ceiling.sh` against it, which is the safe default to forget.
--- Waiting also needs somewhere to put the answer, and that is a property of the **transport**.
--- An approved call is released with `defer`, not `allow`, so the CLI's own gate still runs and the
--- user's granular deny rules are still evaluated; the gate then asks its permission question back
--- over the control channel, which only the duplex transport has. On oneshot there is nobody to
--- answer, so a `defer` would have the gate refuse what the human just approved — hence today's
--- kill-and-retry there, unchanged.
---
--- Passed in rather than read off the descriptor: `process` on a descriptor is the most capable
--- model the backend *can* run, not the one this turn *is* running (`process_model.lua`).
--- @param hook Vibing.HookSpec|nil
--- @param is_duplex boolean|nil whether this turn runs on the resident transport
--- @return boolean
function M.can_wait_for_approval(hook, is_duplex)
  if not is_duplex then
    return false
  end
  local floor = hook and hook.measured_wait_floor_sec
  if type(floor) ~= "number" then
    return false
  end
  return floor > require("vibing.infrastructure.hooks.wait_budget").script_wait_sec()
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
