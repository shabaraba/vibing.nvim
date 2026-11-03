--- Argv for the Command Code CLI.
--- @module vibing.infrastructure.adapter.modules.commandcode_command_builder

local RequestBuilder = require("vibing.infrastructure.adapter.modules.request_builder")
local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")
local WaitBudget = require("vibing.infrastructure.hooks.wait_budget")

local M = {}

M.BINARY = {
  name = "commandcode",
  missing = "Command Code CLI not found. Install it from https://commandcode.ai, or set ai.agents.commandcode.path.",
}

function M._reset_path_cache()
  RequestBuilder.reset_binary(require("vibing.infrastructure.adapter.backends.commandcode").request)
end

--- The permission flags.
---
--- **Command Code's headless gate is all-or-nothing.** In `-p` mode it refuses file writes and shell
--- commands outright unless `--yolo` (alias `--dangerously-skip-permissions`) is passed; measured
--- against 1.88.2, neither `--permission-mode` (including `yolo` and `accept-edits`) nor a
--- `permissions.allow` entry in `.commandcode/settings.json` opens it. So wherever vibing's hook is
--- installed the CLI runs `--yolo` and the generated mod bridge is the gate — the same shape as Pi,
--- whose CLI has no usable gate either, and the reason `hook.keep_in_bypass` is true here.
---
--- **When the hook could not be installed the gate is left as the CLI would have it** — writes and
--- shell refused — rather than opened with nothing behind it. The warning
--- `cli_adapter` already emits says which happened.
--- @param ctx Vibing.RequestContext
--- @return string[]
function M.permission_args(ctx)
  if not ctx.hook_arg then
    return {}
  end
  -- `plan` is Command Code's own read-only mode, which is strictly more than vibing's gate would do
  -- on its own; every other vibing mode has no headless equivalent and leans on the mod bridge.
  if (ctx.opts or {}).permission_mode == "plan" then
    return { "--plan" }
  end
  return { "--yolo" }
end

--- The environment the generated mod bridge reads.
---
--- The bridge is TypeScript loaded into the CLI process, so it cannot call back into this Neovim for
--- the script path or the deadline — both are handed over here, fixed at spawn like the RPC port.
--- @param env table<string, string>
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
function M.apply_env(env, opts, config)
  opts = opts or {}
  if opts.lightweight then
    return
  end
  env.VIBING_COMMANDCODE_HOOK_SCRIPT = SettingsGenerator.get_hook_script_path()
  env.VIBING_COMMANDCODE_HOOK_TIMEOUT_SEC = tostring(WaitBudget.cli_timeout_sec())
end

function M.build(prompt, opts, session_id, config, hook_arg)
  opts = opts or {}
  return RequestBuilder.build(
    require("vibing.infrastructure.adapter.backends.commandcode").request,
    prompt,
    opts,
    session_id,
    config,
    hook_arg
  )
end

return M
