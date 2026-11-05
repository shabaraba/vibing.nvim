--- Ask a backend's CLI for the slash commands it would offer, by the protocol its descriptor names.
---
--- A descriptor's `skill_sources.probe` is data (`protocol`, `args`); this is the only place that
--- turns it into a process. Which protocol a CLI speaks is that CLI's fact and a probe is only
--- declared where it was measured to start no turn and leave no session behind, so adding a
--- backend is one entry in its descriptor, not a change here.
--- @module vibing.infrastructure.completion.command_probe

local RequestBuilder = require("vibing.infrastructure.adapter.modules.request_builder")

local M = {}

--- @class Vibing.CommandProbeOpts
--- @field agent string backend id
--- @field descriptor Vibing.BackendDescriptor
--- @field cwd string
--- @field config Vibing.Config
--- @field plugin_dirs string[]?
--- @field timeout_ms integer?

--- @param probe Vibing.CommandProbe
--- @param opts Vibing.CommandProbeOpts
--- @return string[] argv the CLI's own binary followed by the probe's arguments
local function argv_for(probe, opts)
  local argv = { RequestBuilder.binary_path(opts.descriptor.request, opts.agent, opts.config) }
  vim.list_extend(argv, probe.args or {})
  return argv
end

--- @type table<string, fun(probe: Vibing.CommandProbe, opts: Vibing.CommandProbeOpts, callback: fun(commands: Vibing.CliCommand[]?)): boolean>
local PROTOCOLS = {
  claude_control = function(_, opts, callback)
    return require("vibing.infrastructure.completion.cli_command_list").fetch(opts, callback)
  end,

  acp = function(probe, opts, callback)
    local ok, argv = pcall(argv_for, probe, opts)
    if not ok then
      return false
    end
    return require("vibing.infrastructure.completion.probes.acp").fetch({
      argv = argv,
      cwd = opts.cwd,
      timeout_ms = opts.timeout_ms,
    }, callback)
  end,

  codex_skills = function(probe, opts, callback)
    local ok, argv = pcall(argv_for, probe, opts)
    if not ok then
      return false
    end
    return require("vibing.infrastructure.completion.probes.codex_skills").fetch({
      argv = argv,
      cwd = opts.cwd,
      timeout_ms = opts.timeout_ms,
    }, callback)
  end,
}

--- @param protocol string
--- @return boolean
function M.is_known(protocol)
  return PROTOCOLS[protocol] ~= nil
end

--- @param probe Vibing.CommandProbe
--- @param opts Vibing.CommandProbeOpts
--- @param callback fun(commands: Vibing.CliCommand[]?) called once; nil on any failure
--- @return boolean started false when the job never launched, so the caller can retry later
function M.fetch(probe, opts, callback)
  local run = PROTOCOLS[probe.protocol]
  if not run then
    return false
  end
  return run(probe, opts, callback)
end

return M
