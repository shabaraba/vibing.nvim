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

--- Which generator implements each transport. **One map, not one per question asked of it.**
--- `hook_timeout_sec` dispatches over the same set, and a transport missing from a second copy of
--- this table answers `nil` — which the ordering check reads as "registers no timeout" and skips,
--- rather than reporting.
--- @type table<string, string>
local generators = {
  --- `.vibing/hook-settings-<instance>.json`, handed over with `--settings`.
  settings_file = "vibing.infrastructure.hooks.settings_generator",
  --- A `-c hooks.PreToolUse=[…]` override plus the trust bypass, with the script staged inside the
  --- cwd.
  config_override = "vibing.infrastructure.hooks.codex_settings_generator",
  --- A throwaway plugin under `.vibing/`, loaded with `--plugin-dir`.
  plugin_dir = "vibing.infrastructure.hooks.copilot_settings_generator",
  --- A hook file the CLI discovers from the project tree.
  project_dir = "vibing.infrastructure.hooks.grok_settings_generator",
}

--- Required at call time rather than captured: specs stub a generator's `ensure` on the module
--- table, and a reference taken here would bypass the stub.
---
--- Only the entry point differs per transport, which is why this table holds functions and not
--- just a method name: codex's returns an argv fragment from `get_hook_args`, the other three a
--- path from `ensure`.
local installers = {
  --- Returns the settings path.
  settings_file = function(cwd, dialect)
    return require(generators.settings_file).ensure(cwd, dialect)
  end,
  --- Returns the argv fragment.
  config_override = function(cwd, dialect)
    return require(generators.config_override).get_hook_args(cwd, dialect)
  end,
  --- Returns the plugin directory.
  plugin_dir = function(cwd, dialect)
    return require(generators.plugin_dir).ensure(cwd, dialect)
  end,
  --- Returns the file it wrote; the argv does not reference it.
  project_dir = function(cwd, dialect)
    return require(generators.project_dir).ensure(cwd, dialect)
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
  local module_name = generators[hook and hook.transport]
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
---
--- **Two descriptor fields have to agree, and that is why this takes the descriptor rather than the
--- `hook`.** `hook.measured_wait_floor_sec` says the CLI tolerates a blocked hook that long;
--- `register_chat_bufnr` says the turn carries a chat buffer back. They read as independent — one
--- is about the hook, the other about `nvim_ask_user_question` — but the waiting path needs both,
--- because `_ask_without_killing` has to name the chat that will draw the prompt and own the
--- answer, and the only place that number comes from is `turn.process.chat_bufnr`, which
--- `cli_adapter` fills in **only** when `register_chat_bufnr` is true.
---
--- Requiring just the floor is not a prompt drawn in the wrong place; it is **no prompt at all**.
--- The waiting branch is taken, finds no bufnr, and writes a deny with an internal-error reason —
--- so every `ask` on that backend is refused without anyone being asked. copilot shipped exactly
--- that combination (floor 1700, `register_chat_bufnr = false`), which silently killed the Tool
--- Approval UI it already had. The kill path needs no bufnr, so a backend that fails this test
--- keeps working; it simply keeps the old kill-and-retry shape.
---
--- Read the conjunction as "measured **and** wired". Lifting the second half is not a matter of
--- flipping the flag: the waiting path has only ever been exercised on claude, so wiring a second
--- backend means measuring that backend's own approval UI, not trusting this function to cover it.
--- `conformance/descriptor_shape_spec.lua` recomputes this answer from both raw fields for every
--- registered descriptor, so adding a floor to a backend that is not wired fails the suite instead
--- of disabling its approvals.
--- @param descriptor table|nil the backend descriptor (`adapter/backends/<id>.lua`)
--- @return boolean
function M.can_wait_for_approval(descriptor)
  if not (descriptor and descriptor.register_chat_bufnr) then
    return false
  end
  local hook = descriptor.hook
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
