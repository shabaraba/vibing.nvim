--- CLI command builder for `claude -p` execution
--- Builds the command array for the Claude CLI with streaming JSON I/O
--- @module vibing.infrastructure.adapter.modules.cli_command_builder

local M = {}

local cached_claude_path = nil

--- Resolve model name to CLI-compatible format
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
local function resolve_model(opts, config)
  return opts.model or (config.agent and config.agent.default_model)
end

--- Resolve language setting
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
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

--- Build permission flags for the CLI
--- @param cmd string[]
--- @param opts Vibing.AdapterOpts
local function add_permission_args(cmd, opts)
  local permissions_allow = opts.permissions_allow or {}
  if type(permissions_allow) ~= "table" then
    permissions_allow = {}
  end
  local allow_tools = vim.deepcopy(permissions_allow)
  table.insert(allow_tools, "mcp__vibing-nvim__*")

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

--- Build context prefix for the prompt
--- Reads @file:path entries and formats them as context references
--- @param opts Vibing.AdapterOpts
--- @return string context_prefix Empty string if no context
local function build_context_prefix(opts)
  local context_entries = opts.context or {}
  if #context_entries == 0 then
    return ""
  end

  local parts = {}
  for _, ctx in ipairs(context_entries) do
    if ctx:match("^@file:") then
      local file_ref = ctx:sub(7)
      table.insert(parts, string.format("Context file: %s", file_ref))
    end
  end

  if #parts == 0 then
    return ""
  end

  return table.concat(parts, "\n") .. "\n\n"
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
--- @return string[] Command array for vim.system()
function M.build(prompt, opts, session_id, config, settings_path)
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

  -- Language as system prompt append
  local language = resolve_language(opts, config)
  if language and language ~= "en" then
    local language_utils = require("vibing.core.utils.language")
    local lang_name = language_utils.language_names[language]
    if lang_name then
      table.insert(cmd, "--append-system-prompt")
      table.insert(cmd, string.format("Always respond in %s (%s).", lang_name, language))
    end
  end

  table.insert(cmd, "--setting-sources")
  table.insert(cmd, "user,project")

  -- Build prompt with context prefix (only for new sessions, not resume)
  local full_prompt = prompt
  if not session_id then
    local context_prefix = build_context_prefix(opts)
    full_prompt = context_prefix .. prompt
  end

  -- End of options marker (prevents prompt starting with --- being parsed as flags)
  table.insert(cmd, "--")
  table.insert(cmd, full_prompt)

  return cmd
end

return M
