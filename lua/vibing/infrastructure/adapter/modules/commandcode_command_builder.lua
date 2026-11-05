--- Argv for the Command Code CLI.
--- @module vibing.infrastructure.adapter.modules.commandcode_command_builder

local AskUserQuestionInstructions = require("vibing.infrastructure.adapter.modules.ask_user_question_instructions")
local BackgroundJobInstructions = require("vibing.infrastructure.adapter.modules.background_job_instructions")
local ProcessModel = require("vibing.infrastructure.adapter.modules.process_model")
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

--- The plugin skills, one `--skill` per plugin that has a `skills/` directory.
---
--- **Command Code has no plugin directory** -- it reads no `plugin.json` and has no
--- `--plugin-dir` -- but it does have `--skill <path>`, which takes a skill directory or a
--- directory of skills. Passing each resolved plugin's `skills/` is the skill half of what
--- `--plugin-dir` does elsewhere; the `mcpServers` half travels in the duplex `session/new`
--- request instead (`commandcode_mcp_config`), and on the oneshot transport not at all.
--- Measured on 1.88.2: the flag is accepted
--- ahead of the `acp` subcommand, and the model reports the bundled skill names as available.
---
--- Not on the lightweight path, for the same reason `cli_command_builder.plugin_dir_args` skips
--- it there: skill descriptions cost prompt tokens and a utility call has no tools to invoke them
--- with.
--- @param ctx Vibing.RequestContext
--- @return string[]
function M.skill_args(ctx)
  local args = {}
  for _, plugin_dir in ipairs(require("vibing.infrastructure.plugins.plugin_dirs").resolve(ctx.opts.cwd, ctx.config)) do
    local skills_dir = plugin_dir .. "/skills"
    if vim.fn.isdirectory(skills_dir) == 1 then
      table.insert(args, "--skill")
      table.insert(args, skills_dir)
    end
  end
  return args
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

--- The session-level guidance that on other backends travels in a system prompt.
---
--- Command Code has no system-prompt channel on either transport, so it has to ride in the prompt
--- text. On duplex the protocol adds it when the session is created; here it covers oneshot.
---
--- `tool` is false on oneshot: that transport registers no MCP server at all
--- (`commandcode_mcp_config` is only read for `session/new`), so the background-job policy must
--- not name a tool the model cannot call.
--- @param prompt string
--- @param opts {tool: boolean}|nil
--- @return string
function M.with_instructions(prompt, opts)
  local lines = {}
  vim.list_extend(lines, AskUserQuestionInstructions.lines())
  vim.list_extend(lines, BackgroundJobInstructions.lines({ tool = opts and opts.tool }))
  return table.concat(lines, "\n") .. "\n\n" .. prompt
end

function M.build(prompt, opts, session_id, config, hook_arg)
  opts = opts or {}
  if not opts.lightweight and opts._process_model ~= ProcessModel.DUPLEX then
    prompt = M.with_instructions(prompt, { tool = false })
  end
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
