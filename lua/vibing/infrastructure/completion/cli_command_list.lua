--- Ask the Claude CLI which slash commands it would offer, and spend no tokens doing it.
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

local M = {}

local REQUEST_ID = "vibing-list-commands"

local binary_path =
  CommonBuilder.binary_resolver("claude", "Claude CLI not found in PATH. Please install Claude Code CLI.")

--- Long enough for a cold start of a ~300MB binary on a busy machine; short enough that a CLI
--- which never answers does not pin the job for the rest of the session.
local DEFAULT_TIMEOUT_MS = 15000

--- @class Vibing.CliCommand
--- @field name string
--- @field description string?

--- Pull the command list out of one stdout line, or nil when the line is not our answer.
--- @param line string
--- @return Vibing.CliCommand[]?
local function extract_commands(line)
  local ok, decoded = pcall(vim.json.decode, line)
  if not ok or type(decoded) ~= "table" or decoded.type ~= "control_response" then
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

  local answered = false
  local job_id = nil
  local pending = { "" }

  local function finish(commands)
    if answered then
      return
    end
    answered = true
    if job_id then
      pcall(vim.fn.jobstop, job_id)
    end
    callback(commands)
  end

  job_id = vim.fn.jobstart(argv, {
    cwd = opts.cwd,
    on_stdout = function(_, data)
      if answered or type(data) ~= "table" or #data == 0 then
        return
      end
      -- data[1] continues the partial line left by the previous call; the answer is a single
      -- ~24KB line, so it always arrives split across several of them.
      pending[#pending] = pending[#pending] .. (data[1] or "")
      for i = 2, #data do
        table.insert(pending, data[i])
      end

      -- Every complete line is tried rather than only the first: anything the CLI decides to
      -- print ahead of the response would otherwise be read as the response and discard it.
      for i = 1, #pending - 1 do
        local commands = extract_commands(pending[i])
        if commands then
          finish(commands)
          return
        end
      end
    end,
    on_exit = vim.schedule_wrap(function()
      finish(nil)
    end),
  })

  if type(job_id) ~= "number" or job_id <= 0 then
    job_id = nil
    return false
  end

  vim.fn.chansend(job_id, vim.json.encode({
    type = "control_request",
    request_id = REQUEST_ID,
    request = { subtype = "initialize" },
  }) .. "\n")

  vim.defer_fn(function()
    if not answered and job_id then
      pcall(vim.fn.jobstop, job_id)
    end
  end, opts.timeout_ms or DEFAULT_TIMEOUT_MS)

  return true
end

return M
