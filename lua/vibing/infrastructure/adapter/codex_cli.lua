--- Codex CLI adapter
--- Uses `codex exec --json` for communication
--- @module vibing.infrastructure.adapter.codex_cli

local Base = require("vibing.infrastructure.adapter.base")
local CliRuntime = require("vibing.infrastructure.adapter.modules.cli_runtime")
local CodexCommandBuilder = require("vibing.infrastructure.adapter.modules.codex_command_builder")
local CodexProviderNotice = require("vibing.infrastructure.adapter.modules.codex_provider_notice")
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

CliRuntime.install(CodexCLI, SUPPORTED_FEATURES)

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
---@param on_chunk fun(chunk: string)
---@param on_done fun(response: Vibing.Response)
---@return string handle_id
function CodexCLI:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}

  local debug_mode = vim.g.vibing_debug_stream
  local handle_id = CliRuntime.new_handle_id()
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
  -- Lightweight calls skip hook registration, matching claude_cli.lua. The builder fences them
  -- into a read-only sandbox instead, and routing a title-generation tool call into the chat's
  -- approval UI would prompt the user about a request they never made.
  if permission_mode ~= "bypassPermissions" and not opts.lightweight then
    hook_args = CodexSettingsGenerator.get_hook_args()
  end

  -- The builder raises when the codex binary is missing. send_message.lua does not wrap stream()
  -- in pcall, so without this the chat buffer would show a raw Lua stack trace instead of an
  -- actionable message. Matches copilot_cli.lua.
  local rpc_server = require("vibing.infrastructure.rpc.server")
  local rpc_port = rpc_server.get_port()

  local build_ok, cmd = pcall(CodexCommandBuilder.build, prompt, opts, session_id, self.config, hook_args, rpc_port)
  if not build_ok then
    CliRuntime.report_build_failure(handle_id, cmd, on_done)
    return handle_id
  end
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
      on_chunk(chunk, handle_id)
    end,
  }

  local env = vim.fn.environ()

  if rpc_port then
    local port_str = tostring(rpc_port)
    env.VIBING_NVIM_RPC_PORT = port_str
    env.VIBING_RPC_PORT = port_str
    env.VIBING_NVIM_CONTEXT = "true"
  end
  -- Lets the PreToolUse hook identify which chat buffer's stream it belongs to, so concurrent
  -- chats don't cross-wire each other's approval UI (see ActiveStreamRegistry).
  env.VIBING_HANDLE_ID = handle_id

  -- No chat_bufnr here, unlike claude_cli: it only exists to route nvim_ask_user_question back to
  -- the right chat buffer, and that route is not wired for codex. The two reasons it originally
  -- could not be (#532) are gone as of codex 0.153 -- `-c developer_instructions` is a system
  -- prompt seam, and `-c mcp_servers.<name>.default_tools_approval_mode="approve"` is what lets
  -- a headless MCP call past the approval prompt (openai/codex#24135), which is how the bundled
  -- server now reaches codex at all (codex_plugin_config). The choice-list UI itself is still
  -- untested on this backend, so the developer message tells the model not to call the tool,
  -- and registering a value nothing consumes would only look like a working route.
  ActiveStreamRegistry.register({
    handle_id = handle_id,
    worktree_root = opts._worktree_root,
    adapter = self,
    on_insert_choices = opts.on_insert_choices,
    on_approval_required = opts.on_approval_required,
  })

  local perm_handler = require("vibing.infrastructure.rpc.handlers.permission")
  local ToolVocabulary = require("vibing.infrastructure.adapter.modules.codex_tool_vocabulary")
  perm_handler.set_active_opts(handle_id, vim.tbl_extend("force", opts, { _tool_vocabulary = ToolVocabulary }))

  -- Both registrations above run for a lightweight call too, even though it registers no hook.
  -- They are what `cancel()` and the exit path resolve the handle through, not just permission
  -- routing, and with no hook to fire nothing consumes the permission entry. Skipping them would
  -- leave a lightweight stream unreachable by the very cleanup that unregisters it.

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

  local started = CliRuntime.spawn(self._handles, handle_id, cmd, {
    text = true,
    stdin = "",
    cwd = cwd,
    env = env,
    stdout = StreamHandler.create_stdout_handler(CodexEventProcessor, event_context, function()
      return self._handles[handle_id] == nil
    end),
    stderr = codex_stderr_handler,
  }, StreamHandler.create_exit_handler(handle_id, self._handles, output, error_output, wrapped_on_done), wrapped_on_done)

  if not started then
    return handle_id
  end

  -- `--ignore-user-config` drops the user's model_provider along with their MCP servers (#587),
  -- so say once where these calls are actually going. The argv is what decides, not
  -- `opts.lightweight` alone: the builder documents that flag as a stand-in for a narrower switch
  -- codex does not have yet, so reading the built command is what makes the warning disarm itself
  -- the day the flag stops being used, instead of going on describing a loss that no longer
  -- happens. `lightweight` still guards it because the prompt is the last element of `cmd`, and a
  -- message consisting of exactly that flag would otherwise match. Fired after the spawn above,
  -- since the probe exists to describe that call and must not delay it.
  --
  -- Absent config reads as enabled, not disabled: the default is on (see config.lua), so a caller
  -- that built its config table by hand must not silently lose the warning.
  local notice_enabled = vim.tbl_get(self.config or {}, "agent", "codex_provider_notice", "enabled") ~= false
  if notice_enabled and opts.lightweight and vim.tbl_contains(cmd, "--ignore-user-config") then
    CodexProviderNotice.check(cmd[1], cwd)
  end

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

return CodexCLI
