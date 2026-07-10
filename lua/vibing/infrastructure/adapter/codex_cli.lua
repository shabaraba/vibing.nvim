--- Codex CLI adapter
--- Uses `codex exec --json` for communication
--- @module vibing.infrastructure.adapter.codex_cli

local Base = require("vibing.infrastructure.adapter.base")
local CodexCommandBuilder = require("vibing.infrastructure.adapter.modules.codex_command_builder")
local CodexEventProcessor = require("vibing.infrastructure.adapter.modules.codex_event_processor")
local StreamHandler = require("vibing.infrastructure.adapter.modules.stream_handler")
local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")
local CodexSettingsGenerator = require("vibing.infrastructure.hooks.codex_settings_generator")
local ActiveStreamRegistry = require("vibing.infrastructure.adapter.modules.active_stream_registry")

---@class Vibing.CodexCLIAdapter : Vibing.Adapter
---@field _handles table<string, table>
---@field _session_manager table
local CodexCLI = setmetatable({}, { __index = Base })
CodexCLI.__index = CodexCLI

local INITIAL_RESPONSE_TIMEOUT_MS = 120000

local SUPPORTED_FEATURES = {
  streaming = true,
  tools = true,
  model_selection = true,
  context = true,
  session = true,
}

---@param config Vibing.Config
---@return Vibing.CodexCLIAdapter
function CodexCLI:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, CodexCLI)
  instance.name = "codex_cli"
  instance._handles = {}
  instance._session_manager = SessionManagerModule.new()
  math.randomseed(vim.loop.hrtime())
  return instance
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@return Vibing.Response
function CodexCLI:execute(prompt, opts)
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
function CodexCLI:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}

  local debug_mode = vim.g.vibing_debug_stream
  local handle_id = tostring(vim.loop.hrtime()) .. "_" .. tostring(math.random(100000))
  local session_id = opts._session_id

  if debug_mode then
    vim.notify(
      string.format(
        "[vibing:codex] Starting stream: handle_id=%s, session_id=%s",
        handle_id,
        session_id or "new"
      ),
      vim.log.levels.INFO
    )
  end

  local permission_mode = opts.permission_mode or "default"
  local hook_args = nil
  if permission_mode ~= "bypassPermissions" then
    hook_args = CodexSettingsGenerator.get_hook_args()
  end

  local cmd = CodexCommandBuilder.build(prompt, opts, session_id, self.config, hook_args)
  local output = {}
  local error_output = {} -- filtered stderr (codex noise removed)

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

  local rpc_server = require("vibing.infrastructure.rpc.server")
  local rpc_port = rpc_server.get_port()
  if rpc_port then
    local port_str = tostring(rpc_port)
    env.VIBING_NVIM_RPC_PORT = port_str
    env.VIBING_RPC_PORT = port_str
    env.VIBING_NVIM_CONTEXT = "true"
  end
  -- Lets the PreToolUse hook identify which chat buffer's stream it belongs to, so concurrent
  -- chats don't cross-wire each other's approval UI (see ActiveStreamRegistry).
  env.VIBING_HANDLE_ID = handle_id

  ActiveStreamRegistry.register({
    handle_id = handle_id,
    adapter = self,
    on_insert_choices = opts.on_insert_choices,
    on_approval_required = opts.on_approval_required,
  })

  local perm_handler = require("vibing.infrastructure.rpc.handlers.permission")
  perm_handler.set_active_opts(vim.tbl_extend("force", opts, { _is_codex = true }))

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

  -- Codex always emits "Reading additional input from stdin..." to stderr;
  -- filter it out so the exit handler does not treat the run as an error.
  local codex_stderr_handler = function(err, data)
    if data then
      local cleaned = data:gsub("Reading additional input from stdin%.%.%.%s*", "")
      if cleaned ~= "" then
        table.insert(error_output, cleaned)
      end
    end
  end

  self._handles[handle_id] = vim.system(cmd, {
    text = true,
    stdin = "",
    cwd = cwd,
    env = env,
    stdout = StreamHandler.create_stdout_handler(CodexEventProcessor, event_context, function()
      return self._handles[handle_id] == nil
    end),
    stderr = codex_stderr_handler,
  }, StreamHandler.create_exit_handler(handle_id, self._handles, output, error_output, wrapped_on_done))

  if debug_mode then
    local pid = self._handles[handle_id] and self._handles[handle_id].pid or "unknown"
    vim.notify(string.format("[vibing:codex] Process started: pid=%s", tostring(pid)), vim.log.levels.INFO)
    vim.notify(
      string.format("[vibing:codex] Command: %s", table.concat(cmd, " "):sub(1, 200)),
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
            wrapped_on_done({
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
function CodexCLI:cancel(handle_id)
  -- codex exec spawns child processes (e.g. shells for tool execution) that
  -- inherit the stdout pipe. Killing only the codex parent leaves those
  -- children holding the pipe open, so vim.system()'s exit handler never
  -- fires (it waits for stdout to close), meaning GradientAnimation.stop()
  -- and add_user_section() are never called and the UI stays frozen.
  -- Kill children first via pkill, then the parent.
  local function kill_process(handle)
    if not handle then return end
    local pid = handle.pid
    if not pid or pid <= 0 then return end
    -- Kill direct child processes that may be holding stdout/stderr pipes open
    vim.fn.system(string.format("pkill -9 -P %d 2>/dev/null; true", pid))
    -- Kill the codex process itself
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
function CodexCLI:supports(feature)
  return SUPPORTED_FEATURES[feature] or false
end

---@param session_id string?
---@param handle_id string?
function CodexCLI:set_session_id(session_id, handle_id)
  SessionManagerModule.set(self._session_manager, session_id, handle_id)
end

---@param handle_id string?
---@return string?
function CodexCLI:get_session_id(handle_id)
  return SessionManagerModule.get(self._session_manager, handle_id)
end

---@param handle_id string
function CodexCLI:cleanup_session(handle_id)
  SessionManagerModule.cleanup(self._session_manager, handle_id)
end

function CodexCLI:cleanup_stale_sessions()
  SessionManagerModule.cleanup_stale(self._session_manager, self._handles)
end

return CodexCLI
