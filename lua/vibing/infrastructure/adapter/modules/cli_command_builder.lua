--- CLI command builder for `claude -p` execution
--- Builds the command array for the Claude CLI with streaming JSON I/O
--- @module vibing.infrastructure.adapter.modules.cli_command_builder

local tools_constants = require("vibing.core.constants.tools")
local Shared = require("vibing.infrastructure.adapter.modules.command_builder_shared")

local M = {}

local cached_claude_path = nil

--- Resolve model name to CLI-compatible format
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
local function resolve_model(opts, config)
  return opts.model or (config.agent and config.agent.default_model)
end

--- Build permission flags for the CLI
--- @param cmd string[]
--- @param opts Vibing.AdapterOpts
local function add_permission_args(cmd, opts)
  local permissions_allow = opts.permissions_allow or {}
  if type(permissions_allow) ~= "table" then
    permissions_allow = {}
  end
  local allow_tools = vim.deepcopy(permissions_allow)
  -- The vibing-nvim MCP server may be registered either as a plain user-level MCP server
  -- (mcp__vibing-nvim__<tool>) or as a Claude Code plugin
  -- (mcp__plugin_<marketplace>_<plugin>__<tool>, e.g. mcp__plugin_vibing-nvim_vibing-nvim__<tool>).
  -- Both patterns must be pre-approved here so the CLI's own --allowedTools gate doesn't block
  -- calls before they ever reach vibing.nvim's PreToolUse hook, which already recognizes both
  -- registration styles via can_use_tool.M.is_vibing_nvim_mcp_tool (suffix match).
  local always_allowed = vim.list_extend(
    vim.deepcopy(tools_constants.ALWAYS_ALLOWED_TOOLS),
    { "mcp__vibing-nvim__*", "mcp__plugin_vibing-nvim_vibing-nvim__*" }
  )
  for _, tool in ipairs(always_allowed) do
    if not vim.tbl_contains(allow_tools, tool) then
      table.insert(allow_tools, tool)
    end
  end

  if #allow_tools > 0 then
    table.insert(cmd, "--allowedTools")
    table.insert(cmd, table.concat(allow_tools, ","))
  end

  local permissions_deny = opts.permissions_deny
  if permissions_deny and type(permissions_deny) == "table" and #permissions_deny > 0 then
    table.insert(cmd, "--disallowedTools")
    table.insert(cmd, table.concat(permissions_deny, ","))
  end

  if opts.permission_mode then
    table.insert(cmd, "--permission-mode")
    table.insert(cmd, opts.permission_mode)
  end
end

--- Add optional flag if value is present
--- @param cmd string[]
--- @param flag string
--- @param value any
local function add_flag_if_present(cmd, flag, value)
  if value ~= nil then
    table.insert(cmd, flag)
    table.insert(cmd, tostring(value))
  end
end

--- Build the `claude` CLI command array
--- @param prompt string User prompt
--- @param opts Vibing.AdapterOpts Adapter options
--- @param session_id string|nil Session ID for resumption
--- @param config Vibing.Config Plugin config
--- @param settings_path string|nil Path to hook settings file
--- @param handle_id string|nil This turn's stream handle id, embedded in the system prompt so the
---   model can echo it back on nvim_ask_user_question calls (see ActiveStreamRegistry) — it can't
---   reach the vibing-nvim MCP server via env, since the MCP client only forwards a fixed env
---   whitelist plus the server's static registration config, never the CLI process's own env.
--- @param rpc_port number|nil This Neovim instance's RPC server port, embedded in the system
---   prompt so the model can echo it back on every vibing-nvim MCP tool call. The MCP server's
---   registration hardcodes a single default port (see `.claude-plugin/plugin.json`), so without
---   this it silently targets whichever unrelated Neovim instance happens to be bound to that
---   port when more than one is running.
--- @return string[] Command array for vim.system()
function M.build(prompt, opts, session_id, config, settings_path, handle_id, rpc_port)
  if not cached_claude_path then
    cached_claude_path = vim.fn.exepath("claude")
    if cached_claude_path == "" then
      cached_claude_path = nil
      error("Claude CLI not found in PATH. Please install Claude Code CLI.")
    end
  end

  local cmd = { cached_claude_path }

  table.insert(cmd, "-p")
  table.insert(cmd, "--output-format")
  table.insert(cmd, "stream-json")
  table.insert(cmd, "--verbose")
  table.insert(cmd, "--include-partial-messages")

  add_flag_if_present(cmd, "--model", resolve_model(opts, config))

  if session_id then
    table.insert(cmd, "--resume")
    table.insert(cmd, session_id)
    if opts._is_fork then
      table.insert(cmd, "--fork-session")
    end
  end

  add_permission_args(cmd, opts)

  if settings_path then
    table.insert(cmd, "--settings")
    table.insert(cmd, settings_path)
  end

  -- System prompt additions (worktree convention + chat file path + optional language)
  local system_prompt_lines = Shared.build_system_prompt_lines(opts, config, handle_id, rpc_port)

  table.insert(cmd, "--append-system-prompt")
  table.insert(cmd, table.concat(system_prompt_lines, "\n"))

  table.insert(cmd, "--setting-sources")
  table.insert(cmd, "user,project,local")

  -- Build prompt with context prefix (only for new sessions, not resume)
  local full_prompt = prompt
  if not session_id then
    local context_prefix = Shared.build_context_prefix(opts)
    full_prompt = context_prefix .. prompt
  end

  -- End of options marker (prevents prompt starting with --- being parsed as flags)
  table.insert(cmd, "--")
  table.insert(cmd, full_prompt)

  return cmd
end

return M
