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

--- Active chat frontmatter overrides (set by stream start)
--- @type table|nil
local active_opts = nil

--- Pending hook approvals waiting for user response
--- @type table<string, {tool_name: string, tool_input: table}>
local pending_hook_approvals = {}

local APPROVAL_OPTIONS = {
  { value = "allow_once", label = "allow_once - Allow this execution only" },
  { value = "deny_once", label = "deny_once - Deny this execution only" },
  { value = "allow_for_session", label = "allow_for_session - Allow for this session" },
  { value = "deny_for_session", label = "deny_for_session - Deny for this session" },
}

--- Set active permission opts from chat frontmatter
--- @param opts table
function M.set_active_opts(opts)
  active_opts = opts
end

--- Clear active opts
function M.clear_active_opts()
  active_opts = nil
end

--- Build permission config from frontmatter opts (priority) or global config
--- @return PermissionConfig
local function build_permission_config()
  local config = Config.get()
  local perms = config.permissions or {}
  local o = active_opts or {}

  return {
    allowed_tools = o.permissions_allow or perms.allow or {},
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
local function write_hook_response(request_id, allow)
  local comm_dir = get_comm_dir()
  local res_file = comm_dir .. "/" .. request_id .. ".res"
  local tmp_file = res_file .. ".tmp"

  local decision = allow and "allow" or "deny"
  local json = vim.json.encode({
    hookSpecificOutput = { permissionDecision = decision },
  })

  local f = io.open(tmp_file, "w")
  if f then
    f:write(json)
    f:close()
    os.rename(tmp_file, res_file)
  end
end

--- Handle check_tool_permission RPC request
--- @param params {request_id: string}
--- @return table RPC response
function M.check_tool_permission(params)
  if not params or not params.request_id then
    return { error = "Missing request_id" }
  end

  local request_id = params.request_id

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

  -- AskUserQuestion: deny + insert choices into chat buffer + kill process
  if tool_name == "AskUserQuestion" then
    write_hook_response(request_id, false)
    vim.schedule(function()
      local registry = require("vibing.infrastructure.adapter.modules.active_stream_registry")
      local stream = registry.get()
      if stream then
        if stream.on_insert_choices and tool_input.questions then
          stream.on_insert_choices(tool_input.questions)
        end
        if stream.adapter and stream.handle_id then
          stream.adapter:cancel(stream.handle_id)
        end
      end
    end)
    return { status = "denied", reason = "AskUserQuestion intercepted" }
  end

  local perm_config = build_permission_config()
  local result = can_use_tool_mod.can_use_tool(tool_name, tool_input, perm_config)

  if result.behavior == "allow" then
    write_hook_response(request_id, true)
    return { status = "allowed" }
  elseif result.behavior == "deny" then
    write_hook_response(request_id, false)
    return { status = "denied", reason = result.message }
  else
    -- "ask" → show approval UI in chat buffer, hook blocks until user responds
    pending_hook_approvals[request_id] = {
      tool_name = tool_name,
      tool_input = tool_input,
    }

    -- Clean up if user never responds (hook script times out after 120s)
    vim.defer_fn(function()
      pending_hook_approvals[request_id] = nil
    end, 130000)

    vim.schedule(function()
      local registry = require("vibing.infrastructure.adapter.modules.active_stream_registry")
      local stream = registry.get()

      if stream and stream.on_approval_required then
        stream.on_approval_required(tool_name, tool_input, APPROVAL_OPTIONS, request_id)
      else
        write_hook_response(request_id, false)
        pending_hook_approvals[request_id] = nil
      end
    end)
    return { status = "pending" }
  end
end

--- Resolve a pending hook approval (called from chat buffer after user responds)
--- @param request_id string
--- @param allow boolean
function M.resolve_hook_approval(request_id, allow)
  local pending = pending_hook_approvals[request_id]
  if not pending then
    return
  end

  pending_hook_approvals[request_id] = nil
  write_hook_response(request_id, allow)
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
  pending_hook_approvals = {}
end

--- Get current session state
function M.get_session_state()
  return vim.deepcopy(session_state)
end

return M
