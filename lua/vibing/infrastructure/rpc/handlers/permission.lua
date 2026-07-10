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
local function write_hook_response(request_id, allow)
  local comm_dir = get_comm_dir()
  local res_file = comm_dir .. "/" .. request_id .. ".res"
  local tmp_file = res_file .. ".tmp"

  local decision = allow and "allow" or "deny"
  local json = vim.json.encode({
    hookSpecificOutput = { permissionDecision = decision },
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

  if active_opts and active_opts._is_codex then
    tool_name = CODEX_TOOL_ALIASES[tool_name] or tool_name
  end

  -- Kill process first, call UI callback, then write deny response.
  -- Used by both AskUserQuestion and "ask" permission paths.
  local function cancel_and_deny(on_stream_fn)
    vim.schedule(function()
      local registry = require("vibing.infrastructure.adapter.modules.active_stream_registry")
      local stream = registry.get()
      if stream then
        if stream.adapter and stream.handle_id then
          stream.adapter:cancel(stream.handle_id)
        end
        on_stream_fn(stream)
      end
      write_hook_response(request_id, false)
    end)
  end

  if tool_name == "AskUserQuestion" then
    cancel_and_deny(function(stream)
      if stream.on_insert_choices and tool_input.questions then
        stream.on_insert_choices(tool_input.questions)
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
    -- "ask" → kill process first, show approval UI, then write deny
    -- User's approval choice updates session state; Claude retries on next message
    cancel_and_deny(function(stream)
      if stream.on_approval_required then
        stream.on_approval_required(tool_name, tool_input, APPROVAL_OPTIONS, request_id)
      end
    end)
    return { status = "pending" }
  end
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
