---@class Vibing.CommandBuilder
---Handles construction of Node.js command-line arguments for the Agent SDK wrapper.
---Combines global config and frontmatter (opts) to build the command array.
local M = {}

---@param config Vibing.Config
---@return string
local function get_node_executable(config)
  local dev_mode = config.node and config.node.dev_mode or false
  if dev_mode then
    local bun_cmd = vim.fn.exepath("bun")
    if bun_cmd == "" then
      vim.notify(
        "[vibing.nvim] Error: bun not found in PATH. " ..
        "Please install bun or set node.dev_mode = false.",
        vim.log.levels.ERROR
      )
      error("bun executable not found in PATH")
    end
    return bun_cmd
  end

  if config.node and config.node.executable and config.node.executable ~= "auto" then
    local custom_exec = config.node.executable
    local is_absolute = custom_exec:match("^/")
    local is_valid = is_absolute
      and vim.fn.executable(custom_exec) == 1
      or (not is_absolute and vim.fn.exepath(custom_exec) ~= "")

    if not is_valid then
      vim.notify(
        string.format("[vibing.nvim] Error: Node.js executable '%s' not found.", custom_exec),
        vim.log.levels.ERROR
      )
      error(string.format("Node.js executable not found: %s", custom_exec))
    end
    return custom_exec
  end

  local node_cmd = vim.fn.exepath("node")
  return node_cmd ~= "" and node_cmd or "node"
end

---@param opts Vibing.AdapterOpts
---@param config Vibing.Config
---@return string?
local function resolve_mode(opts, config)
  return opts.mode or (config.agent and config.agent.default_mode)
end

---@param opts Vibing.AdapterOpts
---@param config Vibing.Config
---@return string?
local function resolve_model(opts, config)
  return opts.model or (config.agent and config.agent.default_model)
end

---@param opts Vibing.AdapterOpts
---@param config Vibing.Config
---@return string?
local function resolve_language(opts, config)
  local language = opts.language
  if not language and config.language then
    if type(config.language) == "table" then
      language = config.language.default or config.language.chat
    else
      language = config.language
    end
  end
  return type(language) == "string" and language or nil
end

---@param cmd string[]
---@param opts Vibing.AdapterOpts
local function add_context_args(cmd, opts)
  for _, ctx in ipairs(opts.context or {}) do
    if ctx:match("^@file:") then
      table.insert(cmd, "--context")
      table.insert(cmd, ctx:sub(7))
    end
  end
end

---@param cmd string[]
---@param opts Vibing.AdapterOpts
local function add_permission_args(cmd, opts)
  -- Ensure permissions_allow is a table
  local permissions_allow = opts.permissions_allow or {}
  if type(permissions_allow) ~= "table" then
    permissions_allow = {}
  end
  local allow_tools = vim.deepcopy(permissions_allow)
  -- Always include vibing-nvim MCP tools (ensures #allow_tools >= 1)
  table.insert(allow_tools, "mcp__vibing-nvim__*")

  -- Always add --allow flag (at minimum contains vibing-nvim MCP tools)
  table.insert(cmd, "--allow")
  table.insert(cmd, table.concat(allow_tools, ","))

  -- Ensure permissions_deny is a table
  local permissions_deny = opts.permissions_deny
  if permissions_deny and type(permissions_deny) == "table" and #permissions_deny > 0 then
    table.insert(cmd, "--deny")
    table.insert(cmd, table.concat(permissions_deny, ","))
  end

  -- Ensure permissions_ask is a table
  local permissions_ask = opts.permissions_ask
  if permissions_ask and type(permissions_ask) == "table" and #permissions_ask > 0 then
    table.insert(cmd, "--ask")
    table.insert(cmd, table.concat(permissions_ask, ","))
  end

  -- Session-level allow tools
  local session_allow = opts.permissions_session_allow
  if session_allow and type(session_allow) == "table" and #session_allow > 0 then
    table.insert(cmd, "--session-allow")
    table.insert(cmd, table.concat(session_allow, ","))
  end

  -- Session-level deny tools
  local session_deny = opts.permissions_session_deny
  if session_deny and type(session_deny) == "table" and #session_deny > 0 then
    table.insert(cmd, "--session-deny")
    table.insert(cmd, table.concat(session_deny, ","))
  end

  -- Permission mode
  if opts.permission_mode then
    table.insert(cmd, "--permission-mode")
    table.insert(cmd, opts.permission_mode)
  end
end

---@param cmd string[]
---@param config Vibing.Config
local function add_permission_rules(cmd, config)
  local rules = config.permissions and config.permissions.rules
  if rules and #rules > 0 then
    table.insert(cmd, "--rules")
    table.insert(cmd, vim.json.encode(rules))
  end
end

---@param cmd string[]
---@param flag string
---@param value any
local function add_flag_if_present(cmd, flag, value)
  if value ~= nil then
    table.insert(cmd, flag)
    table.insert(cmd, tostring(value))
  end
end

---@param cmd string[]
---@param config Vibing.Config
local function add_additional_flags(cmd, config)
  add_flag_if_present(cmd, "--prioritize-vibing-lsp", config.agent and config.agent.prioritize_vibing_lsp)
  add_flag_if_present(cmd, "--mcp-enabled", config.mcp and config.mcp.enabled)
  add_flag_if_present(cmd, "--tool-result-display", config.ui and config.ui.tool_result_display)

  local save_location_type = config.chat and config.chat.save_location_type
  add_flag_if_present(cmd, "--save-location-type", save_location_type)

  if save_location_type == "custom" then
    add_flag_if_present(cmd, "--save-dir", config.chat and config.chat.save_dir)
  end
end

---@param cmd string[]
local function add_rpc_port(cmd)
  local rpc_server = require("vibing.infrastructure.rpc.server")
  local rpc_port = rpc_server.get_port()
  if rpc_port then
    table.insert(cmd, "--rpc-port")
    table.insert(cmd, tostring(rpc_port))
  end
end

---@param wrapper_path string
---@param prompt string
---@param opts Vibing.AdapterOpts
---@param session_id string?
---@param config Vibing.Config
---@return string[]
function M.build(wrapper_path, prompt, opts, session_id, config)
  local cmd = { get_node_executable(config), wrapper_path }

  -- Use cwd from opts (worktree) if set, otherwise use current working directory
  local cwd = opts.cwd or vim.fn.getcwd()
  table.insert(cmd, "--cwd")
  table.insert(cmd, cwd)

  add_flag_if_present(cmd, "--mode", resolve_mode(opts, config))
  add_flag_if_present(cmd, "--model", resolve_model(opts, config))
  add_context_args(cmd, opts)
  add_flag_if_present(cmd, "--session", session_id)
  add_permission_args(cmd, opts)
  add_permission_rules(cmd, config)
  add_additional_flags(cmd, config)
  add_flag_if_present(cmd, "--language", resolve_language(opts, config))
  add_rpc_port(cmd)

  table.insert(cmd, "--prompt")
  table.insert(cmd, prompt)

  return cmd
end

return M
