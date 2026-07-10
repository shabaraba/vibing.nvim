--- RPC handler for tool permission checks from pre-tool-use hook
--- @module vibing.infrastructure.rpc.handlers.permission

local can_use_tool_mod = require("vibing.infrastructure.permissions.can_use_tool")
local Config = require("vibing.config")

local M = {}

--- Session-level permission state (shared across all hook invocations)
--- @type {allowed: string[], denied: string[]}
local session_state = {
  allowed = {},
  denied = {},
}

--- Active chat frontmatter overrides, keyed by handle_id (set by stream start). A single shared
--- slot would let one chat buffer's opts silently apply to another's permission checks whenever
--- two chats stream concurrently (see ActiveStreamRegistry for the same class of bug).
--- @type table<string, table>
local active_opts_by_handle = {}

--- Codex uses different tool names than Claude for equivalent operations.
--- This mapping ensures frontmatter permissions work identically across adapters.
local CODEX_TOOL_ALIASES = {
  apply_patch = "Edit", -- Codex's file patch tool maps to Claude's Edit
}

local APPROVAL_OPTIONS = {
  { value = "allow_once", label = "allow_once - Allow this execution only" },
  { value = "deny_once", label = "deny_once - Deny this execution only" },
  { value = "allow_for_session", label = "allow_for_session - Allow for this session" },
  { value = "deny_for_session", label = "deny_for_session - Deny for this session" },
}

--- Set active permission opts from chat frontmatter
--- @param handle_id string
--- @param opts table
function M.set_active_opts(handle_id, opts)
  active_opts_by_handle[handle_id] = opts
end

--- Clear active opts
--- @param handle_id string
function M.clear_active_opts(handle_id)
  active_opts_by_handle[handle_id] = nil
end

--- Resolve the frontmatter opts for a given handle_id. Falls back to the sole registered entry
--- when handle_id is nil/unmatched and exactly one chat is active (back-compat for hook
--- processes that don't yet pass VIBING_HANDLE_ID); returns nil rather than guessing when
--- multiple chats are active. Mirrors ActiveStreamRegistry.get()'s fallback.
--- @param handle_id string|nil
--- @return table|nil
local function get_active_opts(handle_id)
  if handle_id and active_opts_by_handle[handle_id] then
    return active_opts_by_handle[handle_id]
  end
  local only_handle_id, only_opts = next(active_opts_by_handle)
  if only_handle_id ~= nil and next(active_opts_by_handle, only_handle_id) == nil then
    return only_opts
  end
  return nil
end

--- Build permission config from frontmatter opts (priority) or global config
--- @param handle_id string|nil
--- @return PermissionConfig
local function build_permission_config(handle_id)
  local config = Config.get()
  local perms = config.permissions or {}
  local o = get_active_opts(handle_id) or {}

  return {
    allowed_tools = o.permissions_allow or perms.allow or {},
    denied_tools = o.permissions_deny or perms.deny or {},
    asked_tools = o.permissions_ask or perms.ask or {},
    session_allowed_tools = session_state.allowed,
    session_denied_tools = session_state.denied,
    permission_rules = perms.rules or {},
    permission_mode = o.permission_mode or perms.mode or "default",
    mcp_enabled = config.mcp and config.mcp.enabled or false,
  }
end

--- Get the communication directory for a given RPC port
--- @return string
local function get_comm_dir()
  local rpc_server = require("vibing.infrastructure.rpc.server")
  local port = rpc_server.get_port()
  return "/tmp/vibing-hook-" .. tostring(port or 0)
end

--- Write response file for hook script
--- @param request_id string
--- @param allow boolean
--- @param reason? string Surfaced to the model as the tool_result when the underlying process
---   was NOT successfully cancelled (e.g. cancel_and_deny's fallback path). When cancellation
---   does succeed, the process is killed before this response can ever reach the model, so the
---   reason is moot in that case — it only matters for the failure path.
local function write_hook_response(request_id, allow, reason)
  local comm_dir = get_comm_dir()
  local res_file = comm_dir .. "/" .. request_id .. ".res"
  local tmp_file = res_file .. ".tmp"

  local decision = allow and "allow" or "deny"
  local output = { permissionDecision = decision }
  if reason then
    output.permissionDecisionReason = reason
  end
  local json = vim.json.encode({
    hookSpecificOutput = output,
  })

  local f, err = io.open(tmp_file, "w")
  if f then
    f:write(json)
    f:close()
    os.rename(tmp_file, res_file)
  else
    vim.schedule(function()
      vim.notify(
        string.format("[vibing:hook] Failed to write tmp file %s: %s", tmp_file, err or "unknown"),
        vim.log.levels.ERROR
      )
    end)
    local fallback_f, fallback_err = io.open(res_file, "w")
    if fallback_f then
      local deny_json = vim.json.encode({
        hookSpecificOutput = { permissionDecision = "deny" },
      })
      fallback_f:write(deny_json)
      fallback_f:close()
    else
      vim.schedule(function()
        vim.notify(
          string.format("[vibing:hook] Fallback write also failed %s: %s", res_file, fallback_err or "unknown"),
          vim.log.levels.ERROR
        )
      end)
    end
  end
end

--- Handle check_tool_permission RPC request
--- @param params {request_id: string, handle_id: string?}
--- @return table RPC response
function M.check_tool_permission(params)
  if not params or not params.request_id then
    return { error = "Missing request_id" }
  end

  local request_id = params.request_id
  local handle_id = params.handle_id
  if handle_id == "" then
    handle_id = nil
  end

  local comm_dir = get_comm_dir()
  local req_file = comm_dir .. "/" .. request_id .. ".req"

  local f = io.open(req_file, "r")
  if not f then
    write_hook_response(request_id, true)
    return { status = "allowed", reason = "request file not found" }
  end

  local content = f:read("*a")
  f:close()

  local ok, hook_input = pcall(vim.json.decode, content)
  if not ok or not hook_input then
    write_hook_response(request_id, true)
    return { status = "allowed", reason = "invalid request JSON" }
  end

  local tool_name = hook_input.tool_name or ""
  local tool_input = hook_input.tool_input or {}
  local active_opts = get_active_opts(handle_id)

  if active_opts and active_opts._is_codex then
    tool_name = CODEX_TOOL_ALIASES[tool_name] or tool_name
  end

  -- Kill process first, call UI callback, then write deny response. Used by both
  -- AskUserQuestion and "ask" permission paths. The deny response only reaches the model when
  -- cancellation fails to find a stream (see fallback_reason below) — when the process is
  -- successfully killed, it dies before it could ever process that response.
  local function cancel_and_deny(on_stream_fn, fallback_reason)
    vim.schedule(function()
      local registry = require("vibing.infrastructure.adapter.modules.active_stream_registry")
      local stream = registry.get(handle_id)
      local reason = nil
      if stream then
        if stream.adapter and stream.handle_id then
          stream.adapter:cancel(stream.handle_id)
        end
        on_stream_fn(stream)
      else
        vim.notify("[vibing] cancel_and_deny: no active stream found", vim.log.levels.WARN)
        reason = fallback_reason
      end
      write_hook_response(request_id, false, reason)
    end)
  end

  local perm_config = build_permission_config(handle_id)

  -- Native AskUserQuestion is unavailable in headless `claude -p` mode and is fully opaque to us
  -- (the SDK executes it internally), so the only way to handle it is to intercept + deny it here
  -- and render the choice UI ourselves. This branch is a harmless fallback kept in case the
  -- native tool is ever offered. vibing.nvim's own mcp__vibing-nvim__nvim_ask_user_question tool
  -- is the primary path and does NOT go through this hook: since we fully control its execution,
  -- its handler calls M.ask_user_question() (below) directly instead of being denied here.
  local is_ask_user_question_tool = tool_name == "AskUserQuestion"

  if is_ask_user_question_tool then
    cancel_and_deny(function(stream)
      if stream.on_insert_choices and tool_input.questions then
        stream.on_insert_choices(tool_input.questions)
      end
    end, "vibing.nvim could not find the chat buffer to show this question in (internal error). Ask the question as plain text instead of retrying this tool.")
    return { status = "denied", reason = "AskUserQuestion intercepted" }
  end

  local result = can_use_tool_mod.can_use_tool(tool_name, tool_input, perm_config)

  if result.behavior == "allow" then
    write_hook_response(request_id, true)
    return { status = "allowed" }
  elseif result.behavior == "deny" then
    write_hook_response(request_id, false)
    return { status = "denied", reason = result.message }
  else
    -- "ask" → kill process first, show approval UI, then write deny
    -- User's approval choice updates session state; Claude retries on next message
    cancel_and_deny(function(stream)
      if stream.on_approval_required then
        stream.on_approval_required(tool_name, tool_input, APPROVAL_OPTIONS, request_id)
      end
    end, "vibing.nvim could not find the chat buffer to show the approval prompt in (internal error). Do not retry this tool immediately.")
    return { status = "pending" }
  end
end

--- Handle `ask_user_question` RPC request from the vibing-nvim MCP server's
--- `nvim_ask_user_question` tool handler. Unlike native AskUserQuestion (intercepted via
--- PreToolUse hook above, since the SDK executes it as a black box), this is vibing.nvim's own
--- MCP tool: its handler calls this directly instead of returning a real tool_result, so there is
--- no hook/deny plumbing here — just cancel the in-flight turn and show the same choice-list UI.
--- The killed turn means this RPC's return value is never seen by the model; the user's next
--- chat message (a fresh `--resume`d turn) delivers their answer instead.
--- @param params {handle_id: string?, questions: table[]}
--- @return table RPC response
function M.ask_user_question(params)
  if not params or not params.questions then
    return { status = "error", reason = "Missing questions" }
  end

  local handle_id = params.handle_id
  if handle_id == "" then
    handle_id = nil
  end

  local registry = require("vibing.infrastructure.adapter.modules.active_stream_registry")
  local stream = registry.get(handle_id)
  if not stream then
    return {
      status = "error",
      reason = "vibing.nvim could not find the chat buffer to show this question in (internal error).",
    }
  end

  if stream.adapter and stream.handle_id then
    local cancel_ok, cancel_err = pcall(function()
      stream.adapter:cancel(stream.handle_id)
    end)
    if not cancel_ok then
      vim.notify("[vibing] Failed to cancel stream for ask_user_question: " .. tostring(cancel_err), vim.log.levels.WARN)
    end
  end
  if stream.on_insert_choices then
    stream.on_insert_choices(params.questions)
  end

  return { status = "ok" }
end

--- Add tool to session allow list
function M.add_session_allow(tool_pattern, once)
  can_use_tool_mod.add_session_allow(session_state.allowed, tool_pattern, once)
end

--- Add tool to session deny list
function M.add_session_deny(tool_pattern, once)
  can_use_tool_mod.add_session_deny(session_state.denied, tool_pattern, once)
end

--- Reset session state
function M.reset_session()
  session_state.allowed = {}
  session_state.denied = {}
end

--- Get current session state
function M.get_session_state()
  return vim.deepcopy(session_state)
end

return M
