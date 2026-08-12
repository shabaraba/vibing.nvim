--- CLI command builder for `claude -p` execution
--- Builds the command array for the Claude CLI with streaming JSON I/O
--- @module vibing.infrastructure.adapter.modules.cli_command_builder

local tools_constants = require("vibing.core.constants.tools")
local worktree_constants = require("vibing.core.constants.worktree")

local M = {}

local DEFAULT_SETTING_SOURCES = { "user", "project", "local" }
local VALID_SETTING_SOURCES = { user = true, project = true, ["local"] = true }

local cached_claude_path = nil

--- Resolve the `--setting-sources` list, falling back to the default when config
--- is missing, malformed, or contains entries outside `user`/`project`/`local`.
--- @param config Vibing.Config
--- @return string[]
local function resolve_setting_sources(config)
  local setting_sources = config.agent and config.agent.setting_sources
  if type(setting_sources) ~= "table" or #setting_sources == 0 then
    return DEFAULT_SETTING_SOURCES
  end

  for _, source in ipairs(setting_sources) do
    if type(source) ~= "string" or not VALID_SETTING_SOURCES[source] then
      return DEFAULT_SETTING_SOURCES
    end
  end

  return setting_sources
end

--- Resolve model name to CLI-compatible format
--- Lightweight calls (title generation, summarize, daily summary) always use
--- config.agent.utility_model, taking priority over opts.model.
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
local function resolve_model(opts, config)
  if opts.lightweight then
    return (config.agent and config.agent.utility_model) or "haiku"
  end
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
--- @param rpc_port number|nil This Neovim instance's RPC server port, embedded in the system
---   prompt so the model can echo it back on every vibing-nvim MCP tool call. The MCP server
---   cannot read it from its own environment (MCP clients forward only a fixed env whitelist),
---   and without it the server falls back to the instance registry — which refuses to choose
---   once more than one Neovim is live, the normal case with worktrees and concurrent chats.
--- @return string[] Command array for vim.system()
--- Forget the resolved binary path. Test seam only: the cache is process-wide, so a spec that
--- wants to exercise the "CLI missing" path has to clear what an earlier spec resolved.
function M._reset_path_cache()
  cached_claude_path = nil
end

function M.build(prompt, opts, session_id, config, settings_path, rpc_port)
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

  if opts.lightweight then
    -- Lightweight calls need no tools: skip permission args/hooks entirely and empty out the
    -- CLI's built-in tool set. --tools "" removes the tools rather than gating them, which is
    -- why it works where the alternatives don't: an empty --allowedTools alone does NOT block
    -- execution (verified — with no --permission-mode, or with --permission-mode dontAsk, the
    -- model still invokes Bash/Write despite an empty allow list), and --permission-mode plan
    -- does hard-block but leaks plan-mode meta-commentary ("this isn't a planning task...")
    -- into plain text-generation output, corrupting title/summary content.
    --
    -- This replaces an earlier --disallowedTools enumeration of the known built-in tools. That
    -- worked, but a denylist has to be updated every time the CLI grows a tool, and it had
    -- already drifted (Agent/TaskCreate were never listed) — see #488. --tools names nothing,
    -- so it cannot drift. Verified against the CLI directly: with --tools "" plus the empty
    -- MCP config below, prompts explicitly ordering Write/Bash produce no file at all.
    --
    -- No version probe: on a claude CLI predating --tools the process just fails, and the three
    -- callers already surface that as response.error — a failed title/summary, not a broken chat.
    table.insert(cmd, "--tools")
    table.insert(cmd, "")
  else
    add_permission_args(cmd, opts)

    if settings_path then
      table.insert(cmd, "--settings")
      table.insert(cmd, settings_path)
    end
  end

  -- System prompt additions (worktree convention + chat file path + optional language). This
  -- entire block must stay byte-for-byte identical across turns of the same conversation —
  -- Anthropic's prompt cache matches on a forward-prefix basis (tools -> system -> messages), so
  -- any per-turn value here (e.g. a freshly generated handle_id) would invalidate the cached
  -- system+history prefix on every single turn. See issue #469.
  -- Lightweight calls have no tools/MCP servers at all, so tool-usage instructions below would
  -- just be wasted prompt tokens describing capabilities that don't exist.
  local system_prompt_lines = {}

  if not opts.lightweight then
    table.insert(
      system_prompt_lines,
      "When creating a git worktree for isolated work, place it under "
        .. worktree_constants.DIR
        .. "<branch-name>/ at the repository root."
    )
    table.insert(
      system_prompt_lines,
      "When you need the user to choose among options (single or multi-select), always call the "
        .. "mcp__vibing-nvim__nvim_ask_user_question tool instead of asking in free text. Do not use "
        .. "the native AskUserQuestion tool for this — it is unavailable in this environment. Pass "
        .. 'this turn\'s "Current vibing.nvim chat buffer number" (given elsewhere in this system '
        .. "prompt) as the chat_bufnr argument."
    )
    table.insert(
      system_prompt_lines,
      "When the user asks to see code, show it rather than describing where it lives: call "
        .. "mcp__vibing-nvim__nvim_list_windows to find a window that is not the chat, open the file "
        .. "there with mcp__vibing-nvim__nvim_win_open_file, move to the line with "
        .. "mcp__vibing-nvim__nvim_set_cursor, and point at the range with "
        .. "mcp__vibing-nvim__nvim_highlight_range. Then explain the point in the chat. If the chat "
        .. "is the only window, make one with mcp__vibing-nvim__nvim_execute and a split command. "
        .. "Skip all of this when the user only wants a path or a name."
    )
    table.insert(
      system_prompt_lines,
      "When reviewing code, put each point next to the code it is about: load the file with "
        .. "mcp__vibing-nvim__nvim_load_buffer and call mcp__vibing-nvim__nvim_annotate for every "
        .. "finding, choosing severity info, warn or error. Keep the chat to the overall verdict "
        .. "and the count, and mention that :VibingClearAnnotations removes the notes."
    )

    if rpc_port then
      table.insert(
        system_prompt_lines,
        "Your rpc_port for this turn is "
          .. tostring(rpc_port)
          .. ". You MUST pass this exact value as the rpc_port argument on every "
          .. "mcp__vibing-nvim__* tool call — never omit it or guess, since other unrelated Neovim "
          .. "instances may be running and reachable on other ports."
      )
    end

    -- Buffer number, not file path: it survives a rename, keeping this prefix byte-stable (#489).
    if opts.chat_bufnr then
      table.insert(system_prompt_lines, "Current vibing.nvim chat buffer number: " .. tostring(opts.chat_bufnr))
    end

    -- Project-local instructions from .vibing/system-prompt.md. Read fresh on every
    -- request, so an edit takes effect from the next message onward; that edit is also
    -- the only thing that invalidates the cached system prefix (see #469 note above).
    -- An unedited file keeps the block byte-for-byte identical across turns.
    -- Resolved against `opts.cwd` (the chat's `working_dir`, e.g. a worktree) first,
    -- like every other cwd-sensitive part of the request, then the Neovim root.
    local project_prompt = require("vibing.core.utils.project_system_prompt").read_for_cwd(opts.cwd)
    if project_prompt then
      table.insert(system_prompt_lines, project_prompt)
    end
  end

  local language = resolve_language(opts, config)
  if language and language ~= "en" then
    local language_utils = require("vibing.core.utils.language")
    local lang_name = language_utils.language_names[language]
    if lang_name then
      table.insert(system_prompt_lines, 1, string.format("Always respond in %s (%s).", lang_name, language))
    end
  end

  table.insert(cmd, "--append-system-prompt")
  table.insert(cmd, table.concat(system_prompt_lines, "\n"))

  table.insert(cmd, "--setting-sources")
  if opts.lightweight then
    table.insert(cmd, "")
    -- No CLAUDE.md/rules, no MCP servers, no hook settings for utility calls.
    table.insert(cmd, "--strict-mcp-config")
    table.insert(cmd, "--mcp-config")
    table.insert(cmd, '{"mcpServers":{}}')
  else
    table.insert(cmd, table.concat(resolve_setting_sources(config), ","))
  end

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
