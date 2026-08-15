--- Grok CLI adapter
--- Uses `grok -p` (--single) with streaming-json format for communication
--- @module vibing.infrastructure.adapter.grok_cli

local Base = require("vibing.infrastructure.adapter.base")
local CliRuntime = require("vibing.infrastructure.adapter.modules.cli_runtime")
local GrokCommandBuilder = require("vibing.infrastructure.adapter.modules.grok_command_builder")
local GrokEventProcessor = require("vibing.infrastructure.adapter.modules.grok_event_processor")
local StreamHandler = require("vibing.infrastructure.adapter.modules.stream_handler")
local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")
local ActiveStreamRegistry = require("vibing.infrastructure.adapter.modules.active_stream_registry")
local GrokSettingsGenerator = require("vibing.infrastructure.hooks.grok_settings_generator")

---@class Vibing.GrokCLIAdapter : Vibing.Adapter
---@field _handles table<string, table>
---@field _session_manager table
local GrokCLI = setmetatable({}, { __index = Base })
GrokCLI.__index = GrokCLI

-- Shared with execute()'s own wait, so the two cannot drift apart.
local INITIAL_RESPONSE_TIMEOUT_MS = CliRuntime.INITIAL_RESPONSE_TIMEOUT_MS

local SUPPORTED_FEATURES = {
  streaming = true,
  tools = true,
  model_selection = true,
  context = true,
  session = true,
}

CliRuntime.install(GrokCLI, SUPPORTED_FEATURES)

---@param config Vibing.Config
---@return Vibing.GrokCLIAdapter
function GrokCLI:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, GrokCLI)
  instance.name = "grok_cli"
  instance._handles = {}
  instance._session_manager = SessionManagerModule.new()
  -- Fetched once per adapter instance rather than per stream() call — vim.fn.environ()
  -- marshals the whole process environment from C, which is wasted work to repeat on every
  -- message when only a handful of keys actually change per call.
  instance._base_env = vim.fn.environ()
  math.randomseed(vim.loop.hrtime())
  return instance
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@param on_chunk fun(chunk: string)
---@param on_done fun(response: Vibing.Response)
---@return string handle_id
function GrokCLI:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}

  local debug_mode = vim.g.vibing_debug_stream
  local handle_id = CliRuntime.new_handle_id()
  local session_id = opts._session_id

  if debug_mode then
    vim.notify(
      string.format(
        "[vibing:grok] Starting stream: handle_id=%s, session_id=%s",
        handle_id,
        session_id or "new"
      ),
      vim.log.levels.INFO
    )
  end

  local rpc_server = require("vibing.infrastructure.rpc.server")
  local rpc_port = rpc_server.get_port()

  local cwd = opts.cwd or vim.fn.getcwd()

  -- Install project PreToolUse hook (reuses bin/hooks/pre-tool-use.sh) unless fully bypassed.
  -- Grok discovers <cwd>/.grok/hooks/*.json when the folder is trusted.
  --
  -- Lightweight calls skip it too, matching claude_cli and codex_cli. The builder takes their
  -- tools away instead, and routing a title-generation tool call into the chat's approval UI
  -- would prompt the user about a request they never made.
  local permission_mode = opts.permission_mode or "default"
  if permission_mode ~= "bypassPermissions" and not opts.lightweight then
    local ok_hook, hook_err = pcall(GrokSettingsGenerator.ensure, cwd)
    if not ok_hook then
      vim.notify(
        string.format("[vibing:grok] Failed to install PreToolUse hook: %s", tostring(hook_err)),
        vim.log.levels.WARN
      )
    end
  end

  -- The builder raises when the grok binary is missing. send_message.lua does not wrap stream()
  -- in pcall, so without this the chat buffer would show a raw Lua stack trace instead of an
  -- actionable message. Matches claude_cli.lua and copilot_cli.lua.
  local build_ok, cmd = pcall(GrokCommandBuilder.build, prompt, opts, session_id, self.config, handle_id, rpc_port)
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
      on_chunk(chunk)
    end,
  }

  -- Lets PreToolUse hook identify which chat buffer's stream it belongs to (see ActiveStreamRegistry).
  local env = vim.tbl_extend("force", self._base_env, { VIBING_HANDLE_ID = handle_id })
  if rpc_port then
    local port_str = tostring(rpc_port)
    env.VIBING_NVIM_RPC_PORT = port_str
    env.VIBING_RPC_PORT = port_str
    env.VIBING_NVIM_CONTEXT = "true"
  end

  ActiveStreamRegistry.register({
    handle_id = handle_id,
    adapter = self,
    on_insert_choices = opts.on_insert_choices,
    on_approval_required = opts.on_approval_required,
  })

  -- Only the fields the permission handler actually reads are kept here (rather than the whole
  -- `opts` table), so closures like on_insert_choices/on_approval_required aren't pinned in
  -- memory a second time for the stream's lifetime — they're already held by ActiveStreamRegistry
  -- above.
  local perm_handler = require("vibing.infrastructure.rpc.handlers.permission")
  -- The handler stays ignorant of which backend it is serving; it just calls whatever
  -- vocabulary it was handed (#516).
  local ToolVocabulary = require("vibing.infrastructure.adapter.modules.grok_tool_vocabulary")
  perm_handler.set_active_opts(handle_id, vim.tbl_extend("force", opts, { _tool_vocabulary = ToolVocabulary }))

  local wrapped_on_done = function(response)
    if not completed then
      completed = true
      ActiveStreamRegistry.unregister(handle_id)
      perm_handler.clear_active_opts(handle_id)
      if timeout_timer then
        vim.fn.timer_stop(timeout_timer)
        timeout_timer = nil
      end
      on_done(response)
    end
  end

  local started = CliRuntime.spawn(self._handles, handle_id, cmd, {
    text = true,
    stdin = "",
    cwd = cwd,
    env = env,
    stdout = StreamHandler.create_stdout_handler(GrokEventProcessor, event_context, function()
      return self._handles[handle_id] == nil
    end),
    stderr = StreamHandler.create_stderr_handler(error_output),
  }, StreamHandler.create_exit_handler(handle_id, self._handles, output, error_output, wrapped_on_done), wrapped_on_done)

  if not started then
    return handle_id
  end

  if debug_mode then
    local pid = self._handles[handle_id] and self._handles[handle_id].pid or "unknown"
    vim.notify(string.format("[vibing:grok] Process started: pid=%s", tostring(pid)), vim.log.levels.INFO)
    vim.notify(
      string.format("[vibing:grok] Command: %s", table.concat(cmd, " "):sub(1, 200)),
      vim.log.levels.DEBUG
    )
  end

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
              -- Without this, send_message's staleness check is skipped entirely: a timeout that
              -- fires after the user cancelled and sent something new would be treated as the new
              -- request's result and reset its session id.
              _handle_id = handle_id,
            })
          end
        end)
      end
    end)
  end

  return handle_id
end

return GrokCLI
