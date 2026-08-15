--- Claude CLI adapter
--- Uses `claude -p` with stream-json format for communication
--- @module vibing.infrastructure.adapter.claude_cli

local Base = require("vibing.infrastructure.adapter.base")
local CliRuntime = require("vibing.infrastructure.adapter.modules.cli_runtime")
local CLICommandBuilder = require("vibing.infrastructure.adapter.modules.cli_command_builder")
local CLIEventProcessor = require("vibing.infrastructure.adapter.modules.cli_event_processor")
local StreamHandler = require("vibing.infrastructure.adapter.modules.stream_handler")
local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")
local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")
local ActiveStreamRegistry = require("vibing.infrastructure.adapter.modules.active_stream_registry")

---@class Vibing.ClaudeCLIAdapter : Vibing.Adapter
---@field _handles table<string, table>
---@field _session_manager table
local ClaudeCLI = setmetatable({}, { __index = Base })
ClaudeCLI.__index = ClaudeCLI

-- Shared with execute()'s own wait, so the two cannot drift apart.
local INITIAL_RESPONSE_TIMEOUT_MS = CliRuntime.INITIAL_RESPONSE_TIMEOUT_MS

local SUPPORTED_FEATURES = {
  streaming = true,
  tools = true,
  model_selection = true,
  context = true,
  session = true,
  dynamic_permissions = true,
}

CliRuntime.install(ClaudeCLI, SUPPORTED_FEATURES)

---@param config Vibing.Config
---@return Vibing.ClaudeCLIAdapter
function ClaudeCLI:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, ClaudeCLI)
  instance.name = "claude_cli"
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
function ClaudeCLI:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}

  local debug_mode = vim.g.vibing_debug_stream
  local handle_id = CliRuntime.new_handle_id()
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

  local cwd = opts.cwd or vim.fn.getcwd()
  local settings_path = nil
  if not opts.lightweight then
    local ok
    ok, settings_path = pcall(SettingsGenerator.ensure, cwd)
    if not ok then
      vim.notify(
        string.format("[vibing:cli] Failed to create hook settings: %s", tostring(settings_path)),
        vim.log.levels.WARN
      )
      settings_path = nil
    end
  end

  local rpc_server = require("vibing.infrastructure.rpc.server")
  local rpc_port = rpc_server.get_port()

  -- The builder raises when the claude binary is missing. send_message.lua does not wrap stream()
  -- in pcall, so without this the chat buffer would show a raw Lua stack trace instead of an
  -- actionable message. Matches copilot_cli.lua.
  local build_ok, cmd = pcall(CLICommandBuilder.build, prompt, opts, session_id, self.config, settings_path, rpc_port)
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
  -- Remove CLAUDECODE to allow nested invocation
  env.CLAUDECODE = nil

  if rpc_port then
    -- The MCP server subprocess gets its own rpc_port from the model echoing back the
    -- system-prompt-embedded value as a tool argument (see cli_command_builder.lua), not from
    -- env — an MCP client only forwards a fixed env whitelist plus the server's static
    -- registration config, never the CLI process's own env.
    env.VIBING_NVIM_RPC_PORT = tostring(rpc_port) -- for hook script
    env.VIBING_NVIM_CONTEXT = "true" -- indicates running inside vibing.nvim
  end
  -- Lets the PreToolUse hook identify which chat buffer's stream it belongs to, so concurrent
  -- chats don't cross-wire each other's AskUserQuestion/approval UI (see ActiveStreamRegistry).
  env.VIBING_HANDLE_ID = handle_id

  ActiveStreamRegistry.register({
    handle_id = handle_id,
    chat_bufnr = opts.chat_bufnr,
    session_id = opts._session_id,
    adapter = self,
    on_insert_choices = opts.on_insert_choices,
    on_approval_required = opts.on_approval_required,
  })

  local perm_handler = require("vibing.infrastructure.rpc.handlers.permission")
  perm_handler.set_active_opts(handle_id, opts)

  local wrapped_on_done = function(response)
    if not completed then
      completed = true
      ActiveStreamRegistry.unregister(handle_id)
      perm_handler.clear_active_opts(handle_id)
      if timeout_timer then
        vim.fn.timer_stop(timeout_timer)
        timeout_timer = nil
      end

      -- Combine every channel that can report a usage limit. Only the stream event carries a
      -- reset timestamp; the StopFailure hook confirms the turn actually died; the error text is
      -- the fallback if either payload shape changes. See core/utils/rate_limit.lua.
      local RateLimit = require("vibing.core.utils.rate_limit")
      local rate_limit_handler = require("vibing.infrastructure.rpc.handlers.rate_limit")
      local merged = RateLimit.merge(
        event_context.rateLimitInfo,
        rate_limit_handler.take_failure(handle_id),
        response.error and RateLimit.from_error_text(tostring(response.error)) or nil
      )
      if merged and merged.rejected then
        response._rate_limit_info = merged
      end

      on_done(response)
    end
  end

  local started = CliRuntime.spawn(self._handles, handle_id, cmd, {
    text = true,
    cwd = cwd,
    env = env,
    stdout = StreamHandler.create_stdout_handler(CLIEventProcessor, event_context, function()
      return self._handles[handle_id] == nil
    end),
    stderr = StreamHandler.create_stderr_handler(error_output),
  }, StreamHandler.create_exit_handler(handle_id, self._handles, output, error_output, wrapped_on_done, function()
    return event_context.resultErrors
  end), wrapped_on_done)

  if not started then
    return handle_id
  end

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

return ClaudeCLI
