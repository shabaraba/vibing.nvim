--- Claude CLI adapter
--- Uses `claude -p` with stream-json format for communication
--- @module vibing.infrastructure.adapter.claude_cli

local Base = require("vibing.infrastructure.adapter.base")
local CLICommandBuilder = require("vibing.infrastructure.adapter.modules.cli_command_builder")
local CLIEventProcessor = require("vibing.infrastructure.adapter.modules.cli_event_processor")
local StreamHandler = require("vibing.infrastructure.adapter.modules.stream_handler")
local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")
local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")
local ActiveStreamRegistry = require("vibing.infrastructure.adapter.modules.active_stream_registry")

---@class Vibing.ClaudeCLIAdapter : Vibing.Adapter
---@field _handles table<string, table>
---@field _session_manager table
---@field _settings_path string|nil
local ClaudeCLI = setmetatable({}, { __index = Base })
ClaudeCLI.__index = ClaudeCLI

local INITIAL_RESPONSE_TIMEOUT_MS = 120000

local SUPPORTED_FEATURES = {
  streaming = true,
  tools = true,
  model_selection = true,
  context = true,
  session = true,
}

---@param config Vibing.Config
---@return Vibing.ClaudeCLIAdapter
function ClaudeCLI:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, ClaudeCLI)
  instance.name = "claude_cli"
  instance._handles = {}
  instance._session_manager = SessionManagerModule.new()
  instance._settings_path = nil
  math.randomseed(vim.loop.hrtime())
  return instance
end

--- Get or create hook settings file (cached)
--- @return string|nil
function ClaudeCLI:_get_settings_path()
  if not self._settings_path then
    local ok, path = pcall(SettingsGenerator.ensure)
    if ok and path then
      self._settings_path = path
    else
      vim.notify(
        string.format("[vibing:cli] Failed to create hook settings: %s", tostring(path)),
        vim.log.levels.WARN
      )
    end
  end
  return self._settings_path
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@return Vibing.Response
function ClaudeCLI:execute(prompt, opts)
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
function ClaudeCLI:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}

  local debug_mode = vim.g.vibing_debug_stream
  local handle_id = tostring(vim.loop.hrtime()) .. "_" .. tostring(math.random(100000))
  local session_id = opts._session_id

  if debug_mode then
    vim.notify(
      string.format(
        "[vibing:cli] Starting stream: handle_id=%s, session_id=%s",
        handle_id,
        session_id or "new"
      ),
      vim.log.levels.INFO
    )
  end

  local cmd = CLICommandBuilder.build(prompt, opts, session_id, self.config, self:_get_settings_path())
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
      on_chunk(chunk)
    end,
  }

  local env = vim.fn.environ()
  -- Remove CLAUDECODE to allow nested invocation
  env.CLAUDECODE = nil

  local rpc_server = require("vibing.infrastructure.rpc.server")
  local rpc_port = rpc_server.get_port()
  if rpc_port then
    local port_str = tostring(rpc_port)
    env.VIBING_NVIM_RPC_PORT = port_str -- for hook script
    env.VIBING_RPC_PORT = port_str -- for MCP server (mcp-server/src/rpc.ts)
    env.VIBING_NVIM_CONTEXT = "true" -- indicates running inside vibing.nvim
  end

  ActiveStreamRegistry.register({
    handle_id = handle_id,
    adapter = self,
    on_insert_choices = opts.on_insert_choices,
    on_approval_required = opts.on_approval_required,
  })

  local perm_handler = require("vibing.infrastructure.rpc.handlers.permission")
  perm_handler.set_active_opts(opts)

  local wrapped_on_done = function(response)
    if not completed then
      completed = true
      ActiveStreamRegistry.unregister(handle_id)
      perm_handler.clear_active_opts()
      if timeout_timer then
        vim.fn.timer_stop(timeout_timer)
        timeout_timer = nil
      end
      on_done(response)
    end
  end

  local cwd = opts.cwd or vim.fn.getcwd()

  self._handles[handle_id] = vim.system(cmd, {
    text = true,
    cwd = cwd,
    env = env,
    stdout = StreamHandler.create_stdout_handler(CLIEventProcessor, event_context),
    stderr = StreamHandler.create_stderr_handler(error_output),
  }, StreamHandler.create_exit_handler(handle_id, self._handles, output, error_output, wrapped_on_done))

  if debug_mode then
    local pid = self._handles[handle_id] and self._handles[handle_id].pid or "unknown"
    vim.notify(string.format("[vibing:cli] Process started: pid=%s", tostring(pid)), vim.log.levels.INFO)
    vim.notify(
      string.format("[vibing:cli] Command: %s", table.concat(cmd, " "):sub(1, 200)),
      vim.log.levels.DEBUG
    )
  end

  -- Session corruption detection timeout
  if session_id then
    timeout_timer = vim.fn.timer_start(INITIAL_RESPONSE_TIMEOUT_MS, function()
      if not received_first_response and not completed and self._handles[handle_id] then
        vim.schedule(function()
          if not completed then
            completed = true
            vim.notify(
              "[vibing] Session resume timeout - killing hung process and resetting session",
              vim.log.levels.WARN
            )
            self:cancel(handle_id)
            on_done({
              error = "Session resume timeout",
              _session_corrupted = true,
              _old_session_id = session_id,
            })
          end
        end)
      end
    end)
  end

  return handle_id
end

---@param handle_id string?
function ClaudeCLI:cancel(handle_id)
  if handle_id then
    local handle = self._handles[handle_id]
    if handle then
      pcall(function()
        if handle.pid and handle.pid > 0 then
          handle:kill(9)
        end
      end)
      self._handles[handle_id] = nil
    end
  else
    for id, handle in pairs(self._handles) do
      pcall(function()
        if handle.pid and handle.pid > 0 then
          handle:kill(9)
        end
      end)
      self._handles[id] = nil
    end
  end
end

---@param feature string
---@return boolean
function ClaudeCLI:supports(feature)
  return SUPPORTED_FEATURES[feature] or false
end

---@param session_id string?
---@param handle_id string?
function ClaudeCLI:set_session_id(session_id, handle_id)
  SessionManagerModule.set(self._session_manager, session_id, handle_id)
end

---@param handle_id string?
---@return string?
function ClaudeCLI:get_session_id(handle_id)
  return SessionManagerModule.get(self._session_manager, handle_id)
end

---@param handle_id string
function ClaudeCLI:cleanup_session(handle_id)
  SessionManagerModule.cleanup(self._session_manager, handle_id)
end

function ClaudeCLI:cleanup_stale_sessions()
  SessionManagerModule.cleanup_stale(self._session_manager, self._handles)
end

return ClaudeCLI
