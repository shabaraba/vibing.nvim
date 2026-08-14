--- Copilot CLI adapter
--- Uses `copilot -p --output-format json` for communication
--- @module vibing.infrastructure.adapter.copilot_cli

local Base = require("vibing.infrastructure.adapter.base")
local CliRuntime = require("vibing.infrastructure.adapter.modules.cli_runtime")
local CopilotCommandBuilder = require("vibing.infrastructure.adapter.modules.copilot_command_builder")
local CopilotEventProcessor = require("vibing.infrastructure.adapter.modules.copilot_event_processor")
local StreamHandler = require("vibing.infrastructure.adapter.modules.stream_handler")
local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")
local ActiveStreamRegistry = require("vibing.infrastructure.adapter.modules.active_stream_registry")

---@class Vibing.CopilotCLIAdapter : Vibing.Adapter
---@field _handles table<string, table>
---@field _session_manager table
local CopilotCLI = setmetatable({}, { __index = Base })
CopilotCLI.__index = CopilotCLI

local INITIAL_RESPONSE_TIMEOUT_MS = 120000

local SUPPORTED_FEATURES = {
  streaming = true,
  tools = true,
  model_selection = true,
  context = true,
  session = true,
  -- False here, true for the others: see architecture.md. #512 tracks making it real.
  dynamic_permissions = false,
}

CliRuntime.install(CopilotCLI, SUPPORTED_FEATURES)

---@param config Vibing.Config
---@return Vibing.CopilotCLIAdapter
function CopilotCLI:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, CopilotCLI)
  instance.name = "copilot_cli"
  instance._handles = {}
  instance._session_manager = SessionManagerModule.new()
  math.randomseed(vim.loop.hrtime())
  return instance
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@param on_chunk fun(chunk: string)
---@param on_done fun(response: Vibing.Response)
---@return string handle_id
function CopilotCLI:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}

  local debug_mode = vim.g.vibing_debug_stream
  local handle_id = CliRuntime.new_handle_id()
  local session_id = opts._session_id

  -- The builder raises when the copilot binary is missing. The caller in send_message.lua
  -- does not wrap stream() in pcall, so without this the chat buffer would show a raw Lua
  -- stack trace instead of an actionable message.
  local build_ok, cmd = pcall(CopilotCommandBuilder.build, prompt, opts, session_id, self.config)
  if not build_ok then
    CliRuntime.report_build_failure(handle_id, cmd, on_done)
    return handle_id
  end

  local output = {}
  local error_output = {}

  local received_first_response = false
  local timeout_timer = nil
  local completed = false

  local function cancel_timeout()
    received_first_response = true
    if timeout_timer then
      vim.fn.timer_stop(timeout_timer)
      timeout_timer = nil
    end
  end

  local event_context = {
    sessionManager = self._session_manager,
    handleId = handle_id,
    opts = opts,
    output = output,
    errorOutput = error_output,
    onFirstResponse = cancel_timeout,
    onChunk = function(chunk)
      cancel_timeout()
      on_chunk(chunk, handle_id)
    end,
  }

  local env = vim.fn.environ()

  local rpc_server = require("vibing.infrastructure.rpc.server")
  local rpc_port = rpc_server.get_port()
  if rpc_port then
    local port_str = tostring(rpc_port)
    env.VIBING_NVIM_RPC_PORT = port_str
    env.VIBING_RPC_PORT = port_str
    env.VIBING_NVIM_CONTEXT = "true"
  end
  env.VIBING_HANDLE_ID = handle_id

  -- Required so nvim_ask_user_question can resolve this stream's chat callbacks
  -- (see rpc/handlers/permission.lua and ActiveStreamRegistry).
  ActiveStreamRegistry.register({
    handle_id = handle_id,
    adapter = self,
    on_insert_choices = opts.on_insert_choices,
    on_approval_required = opts.on_approval_required,
  })

  local wrapped_on_done = function(response)
    if not completed then
      completed = true
      ActiveStreamRegistry.unregister(handle_id)
      if timeout_timer then
        vim.fn.timer_stop(timeout_timer)
        timeout_timer = nil
      end
      on_done(response)
    end
  end

  self._handles[handle_id] = vim.system(cmd, {
    text = true,
    stdin = "",
    cwd = opts.cwd or vim.fn.getcwd(),
    env = env,
    stdout = StreamHandler.create_stdout_handler(CopilotEventProcessor, event_context, function()
      return self._handles[handle_id] == nil
    end),
    stderr = StreamHandler.create_stderr_handler(error_output),
  }, StreamHandler.create_exit_handler(handle_id, self._handles, output, error_output, wrapped_on_done))

  if debug_mode then
    local pid = self._handles[handle_id] and self._handles[handle_id].pid or "unknown"
    vim.notify(string.format("[vibing:copilot] Process started: pid=%s", tostring(pid)), vim.log.levels.INFO)
    vim.notify(
      string.format("[vibing:copilot] Command: %s", table.concat(cmd, " "):sub(1, 200)),
      vim.log.levels.DEBUG
    )
  end

  -- Session corruption detection timeout
  if session_id then
    timeout_timer = vim.fn.timer_start(INITIAL_RESPONSE_TIMEOUT_MS, function()
      if not received_first_response and not completed and self._handles[handle_id] then
        vim.schedule(function()
          if not completed then
            vim.notify(
              "[vibing] Session resume timeout - killing hung process and resetting session",
              vim.log.levels.WARN
            )
            self:cancel(handle_id)
            wrapped_on_done({
              error = "Session resume timeout",
              _session_corrupted = true,
              _old_session_id = session_id,
              _handle_id = handle_id,
            })
          end
        end)
      end
    end)
  end

  return handle_id
end

return CopilotCLI
