---RPC boundary for Neovim-owned background jobs.
--- @module vibing.infrastructure.rpc.handlers.job
local M = {}

local Manager = require("vibing.application.job.manager")
local Bufnr = require("vibing.infrastructure.rpc.handlers.bufnr")

function M.job_start(params)
  params = params or {}
  local from_bufnr = Bufnr.resolve_from_bufnr(params.from_bufnr)
  if not from_bufnr then
    error("Missing from_bufnr parameter (the chat starting the job must name itself)")
  end
  return Manager.start({
    command = params.command,
    name = params.name,
    cwd = params.cwd,
    base_cwd = params.base_cwd,
    from_bufnr = from_bufnr,
    notify = params.notify,
    env = params.env,
    ready_pattern = params.ready_pattern,
    ready_timeout_ms = params.ready_timeout_ms,
  })
end

function M.job_status(params)
  return Manager.status(params)
end

function M.job_list()
  return Manager.list()
end

function M.job_stop(params)
  return Manager.stop(params)
end

function M.job_wait(params)
  return Manager.wait(params)
end

return M
