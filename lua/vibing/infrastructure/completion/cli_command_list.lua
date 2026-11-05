--- Ask the Claude CLI which slash commands it would offer, and spend no tokens doing it.
---
--- Claude-only: the protocol below is Claude's private control channel, so the provider asks it
--- for a Claude chat and never for another backend (see each descriptor's `skill_sources`).
---
--- Built-in skills (`/design`, `/dataviz`, `/code-review`, ...) live inside the `claude` binary,
--- so no filesystem scan can find them. They used to be a hand-written list in two places, which
--- went stale on every CLI release. The CLI answers a `control_request` of subtype `initialize`
--- with the commands it would actually load -- built-ins, user/project skills, and the skills of
--- every plugin it accepted -- and answers it **before** any turn starts, so nothing is sent to
--- the model. Measured against claude 2.1.231: 67 commands in ~800ms, `total_cost_usd` untouched
--- because no request is ever made.
---
--- The turn-start route was measured too and rejected: the `system`/`init` stream event carries
--- the same list in `slash_commands`, but only names (no descriptions), and only once the turn is
--- already under way -- `--max-turns 0` does not prevent it, it just runs the turn anyway.
---
--- This is an undocumented internal protocol, so every layer of the response is checked before it
--- is trusted and an unrecognised shape resolves to `nil` rather than a partial list.
--- @module vibing.infrastructure.completion.cli_command_list

local CommandBuilder = require("vibing.infrastructure.adapter.modules.cli_command_builder")
local CommonBuilder = require("vibing.infrastructure.adapter.modules.command_builder_common")
local LineJob = require("vibing.infrastructure.completion.probes.line_job")

local M = {}

local REQUEST_ID = "vibing-list-commands"

local binary_path =
  CommonBuilder.binary_resolver("claude", "Claude CLI not found in PATH. Please install Claude Code CLI.")

--- @class Vibing.CliCommand
--- @field name string
--- @field description string?
--- @field source "project"|"user"|"bundled"? set by a probe that knows where the command came from

--- Pull the command list out of one decoded stdout line, or nil when the line is not our answer.
--- @param decoded table
--- @return Vibing.CliCommand[]?
local function extract_commands(decoded)
  if decoded.type ~= "control_response" then
    return nil
  end

  local response = decoded.response
  if type(response) ~= "table" or response.request_id ~= REQUEST_ID then
    return nil
  end
  if response.subtype ~= "success" or type(response.response) ~= "table" then
    return nil
  end

  local commands = response.response.commands
  return type(commands) == "table" and commands or nil
end

--- @param opts Vibing.CliCommandListOpts
--- @return string[]
local function build_argv(opts)
  -- `--strict-mcp-config` with no `--mcp-config` leaves the CLI no MCP servers to start. The
  -- command list is identical either way (verified: 67 both ways), and this process is killed the
  -- moment it answers -- launching the user's MCP servers only to orphan them buys nothing.
  local argv = {
    binary_path.resolve(),
    "-p",
    "--output-format",
    "stream-json",
    "--input-format",
    "stream-json",
    "--verbose",
    "--strict-mcp-config",
    "--setting-sources",
    table.concat(CommandBuilder.resolve_setting_sources(opts.config), ","),
  }

  for _, dir in ipairs(opts.plugin_dirs or {}) do
    vim.list_extend(argv, { "--plugin-dir", dir })
  end

  return argv
end

--- @class Vibing.CliCommandListOpts
--- @field cwd string
--- @field config Vibing.Config
--- @field plugin_dirs string[]?
--- @field timeout_ms integer?

--- Fetch the CLI's slash commands asynchronously.
---
--- @param opts Vibing.CliCommandListOpts
--- @param callback fun(commands: Vibing.CliCommand[]?) called once; nil on any failure
--- @return boolean started false when the job never launched, so the caller can retry later
function M.fetch(opts, callback)
  local ok, argv = pcall(build_argv, opts)
  if not ok then
    return false
  end

  return LineJob.run({
    argv = argv,
    cwd = opts.cwd,
    timeout_ms = opts.timeout_ms,
    start = function(send)
      send({
        type = "control_request",
        request_id = REQUEST_ID,
        request = { subtype = "initialize" },
      })
    end,
    on_message = function(message, _, finish)
      local commands = extract_commands(message)
      if commands then
        finish(commands)
      end
    end,
  }, callback)
end

return M
