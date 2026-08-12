--- Copilot CLI adapter
--- Uses `copilot -p --output-format json` for communication
--- @module vibing.infrastructure.adapter.copilot_cli

local Base = require("vibing.infrastructure.adapter.base")
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
}

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
---@return Vibing.Response
function CopilotCLI:execute(prompt, opts)
  opts = opts or {}
  local result = { content = "" }
  local done = false

  self:stream(prompt, opts, function(chunk)
    result.content = result.content .. chunk
  end, function(response)
    if response.error then
      result.error = response.error
    end
    done = true
  end)

  vim.wait(120000, function()
    return done
  end, 100)
  return result
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@param on_chunk fun(chunk: string)
---@param on_done fun(response: Vibing.Response)
---@return string handle_id
function CopilotCLI:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}

  local debug_mode = vim.g.vibing_debug_stream
  local handle_id = string.format("%016x_%x", vim.loop.hrtime(), math.random(100000))
  local session_id = opts._session_id

  -- The builder raises when the copilot binary is missing. The caller in send_message.lua
  -- does not wrap stream() in pcall, so without this the chat buffer would show a raw Lua
  -- stack trace instead of an actionable message.
  local build_ok, cmd = pcall(CopilotCommandBuilder.build, prompt, opts, session_id, self.config)
  if not build_ok then
    local message = type(cmd) == "string" and cmd:gsub("^.*:%d+:%s*", "") or tostring(cmd)
    vim.schedule(function()
      on_done({ content = "", error = message, _handle_id = handle_id })
    end)
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

---@param handle_id string?
function CopilotCLI:cancel(handle_id)
  -- copilot's shell tool spawns children that inherit the stdout pipe. Killing only
  -- the parent leaves them holding it open, so vim.system()'s exit handler never fires
  -- and the chat UI stays frozen. Kill children first, then the parent.
  local function kill_process(handle)
    if not handle then
      return
    end
    local pid = handle.pid
    if not pid or pid <= 0 then
      return
    end
    vim.fn.system(string.format("pkill -9 -P %d 2>/dev/null; true", pid))
    pcall(function()
      handle:kill(9)
    end)
  end

  if handle_id then
    local handle = self._handles[handle_id]
    if handle then
      kill_process(handle)
      self._handles[handle_id] = nil
    end
  else
    for id, handle in pairs(self._handles) do
      kill_process(handle)
      self._handles[id] = nil
    end
  end
end

---@param feature string
---@return boolean
function CopilotCLI:supports(feature)
  return SUPPORTED_FEATURES[feature] or false
end

---@param session_id string?
---@param handle_id string?
function CopilotCLI:set_session_id(session_id, handle_id)
  SessionManagerModule.set(self._session_manager, session_id, handle_id)
end

---@param handle_id string?
---@return string?
function CopilotCLI:get_session_id(handle_id)
  return SessionManagerModule.get(self._session_manager, handle_id)
end

---@param handle_id string
function CopilotCLI:cleanup_session(handle_id)
  SessionManagerModule.cleanup(self._session_manager, handle_id)
end

function CopilotCLI:cleanup_stale_sessions()
  SessionManagerModule.cleanup_stale(self._session_manager, self._handles)
end

return CopilotCLI
