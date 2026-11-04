--- Argv for the OpenCode CLI.
--- @module vibing.infrastructure.adapter.modules.opencode_command_builder

local Notify = require("vibing.core.utils.notify")
local RequestBuilder = require("vibing.infrastructure.adapter.modules.request_builder")
local OpencodeConfig = require("vibing.infrastructure.adapter.modules.opencode_config")

local M = {}

M.BINARY = { name = "opencode", missing = "OpenCode CLI not found. Install it from https://opencode.ai, or set ai.agents.opencode.path." }

function M._reset_path_cache()
  RequestBuilder.reset_binary(require("vibing.infrastructure.adapter.backends.opencode").request)
end

function M.agent_args(ctx)
  local mode = (ctx.opts or {}).permission_mode or "default"
  if mode == "plan" then
    return { "--agent", "plan" }
  end
  return {}
end

function M.auto_args(ctx)
  local mode = (ctx.opts or {}).permission_mode or "default"
  if mode == "auto" or mode == "bypassPermissions" then
    return { "--auto" }
  end
  return {}
end

function M.apply_env(env, opts, config)
  OpencodeConfig.apply(env, opts, config)
end

function M.build(prompt, opts, session_id, config, hook_arg)
  opts = opts or {}
  opts._opencode_plugin_dir = hook_arg
  return RequestBuilder.build(
    require("vibing.infrastructure.adapter.backends.opencode").request,
    prompt,
    opts,
    session_id,
    config,
    hook_arg
  )
end

return M
