--- CLI command builder for `claude -p` execution
--- Builds the command array for the Claude CLI with streaming JSON I/O
--- @module vibing.infrastructure.adapter.modules.cli_command_builder

local tools_constants = require("vibing.core.constants.tools")
local CommonBuilder = require("vibing.infrastructure.adapter.modules.command_builder_common")
local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
local worktree_constants = require("vibing.core.constants.worktree")

local M = {}

local DEFAULT_SETTING_SOURCES = { "user", "project", "local" }
local VALID_SETTING_SOURCES = { user = true, project = true, ["local"] = true }

local binary_path = CommonBuilder.binary_resolver(
  "claude",
  "Claude CLI not found in PATH. Please install Claude Code CLI."
)

--- Resolve the `--setting-sources` list, falling back to the default when config
--- is missing, malformed, or contains entries outside `user`/`project`/`local`.
---
--- Public because `completion/cli_command_list.lua` asks the same CLI which slash commands it
--- would load, and the answer depends on this flag: a narrowed list there and a wider one here
--- would offer commands the chat itself never sees.
--- @param config Vibing.Config
--- @return string[]
function M.resolve_setting_sources(config)
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
    return (config.agent and config.agent.utility_model) or "sonnet"
  end
  return opts.model or (config.agent and config.agent.default_model)
end

--- Resolve the reasoning effort level for this call.
--- Lightweight calls (title generation, summarize, daily summary) use config.agent.utility_effort.
--- It is not paired with a cheap model: utility_model defaults to sonnet because those calls
--- summarize a noisy transcript. Low effort on a capable model is the trade being made.
--- Returns nil when nothing is configured, so no --effort is passed and the CLI's own default
--- applies — that default moves as Anthropic tunes it, and pinning it here would freeze it.
--- Invalid values are dropped with a warning: the CLI accepts an unknown level without complaint
--- and then ignores it, so a typo would otherwise be silent.
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
local function resolve_effort(opts, config)
  local agent = config.agent or {}
  local effort
  if opts.lightweight then
    effort = agent.utility_effort
  else
    effort = opts.effort or agent.default_effort
  end

  if effort == nil then
    return nil
  end

  local Modes = require("vibing.core.constants.modes")
  if not Modes.is_valid_effort(effort) then
    require("vibing.core.utils.notify").warn(
      string.format("Ignoring unknown effort %s (valid: %s)", tostring(effort), table.concat(Modes.EFFORT_LEVELS, ", "))
    )
    return nil
  end

  return effort
end

--- Append tools that are not in the list yet, preserving the user's own ordering
--- @param allow_tools string[]
--- @param tools string[]
local function allow_additionally(allow_tools, tools)
  for _, tool in ipairs(tools) do
    if not vim.tbl_contains(allow_tools, tool) then
      table.insert(allow_tools, tool)
    end
  end
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
  -- Every vibing-nvim MCP registration style (see tools_constants.VIBING_NVIM_MCP_TOOL_PATTERNS)
  -- is pre-approved here, as the CLI's first gate. It is not the load-bearing one: the PreToolUse
  -- hook recognizes them all via can_use_tool.M.is_vibing_nvim_mcp_tool (suffix match, so it isn't
  -- tied to a marketplace name) and returns an explicit allow, which makes the CLI skip its own
  -- gate entirely. A stale entry here is therefore invisible rather than fatal — which is exactly
  -- how the list came to name a marketplace that had already been renamed.
  local always_allowed = vim.list_extend(
    vim.deepcopy(tools_constants.ALWAYS_ALLOWED_TOOLS),
    vim.deepcopy(tools_constants.VIBING_NVIM_MCP_TOOL_PATTERNS)
  )
  allow_additionally(allow_tools, always_allowed)

  -- A subagent-bound chat exists to talk to one agent; without these the CLI's own gate blocks the
  -- only thing it can do. SendMessage is a deferred tool, so ToolSearch has to come along to find
  -- it. Both spellings of the launcher are listed because the CLI renamed Task to Agent.
  if opts._subagent_id then
    allow_additionally(allow_tools, { "Agent", "Task", "SendMessage", "ToolSearch" })
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

--- Forget the resolved binary path. Test seam only: the cache is process-wide, so a spec that
--- wants to exercise the "CLI missing" path has to clear what an earlier spec resolved.
function M._reset_path_cache()
  binary_path.reset()
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
function M.build(prompt, opts, session_id, config, settings_path, rpc_port)
  local cmd = { binary_path.resolve() }

  table.insert(cmd, "-p")
  table.insert(cmd, "--output-format")
  table.insert(cmd, "stream-json")
  table.insert(cmd, "--verbose")
  table.insert(cmd, "--include-partial-messages")

  add_flag_if_present(cmd, "--model", resolve_model(opts, config))
  add_flag_if_present(cmd, "--effort", resolve_effort(opts, config))

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

    -- Without this the CLI swallows everything a subagent says and only its final tool_result
    -- surfaces. Opt-in because it makes long delegated turns much noisier.
    local subagent = config.agent and config.agent.subagent
    if subagent and subagent.enabled then
      table.insert(cmd, "--forward-subagent-text")
    end

    -- vibing.nvim's own plugin (the nvim_* MCP tools and the bundled skills) is loaded for this
    -- session only, from this checkout, instead of being installed into Claude Code's user
    -- scope. That is what keeps the MCP server from drifting away from the Neovim plugin it
    -- serves -- a worktree now runs its own copy rather than the globally installed one.
    -- `.vibing/plugins/*/` rides along on the same flag.
    --
    -- Not passed on the lightweight path: `core/types.lua` obliges utility calls to load no
    -- tools and no project config. `--strict-mcp-config` already blocks the MCP servers there
    -- (verified: zero connection log lines), but a plugin's skill descriptions still cost prompt
    -- tokens, and lightweight has no tools to invoke them with anyway.
    for _, plugin_dir in ipairs(PluginDirs.resolve(opts.cwd, config)) do
      table.insert(cmd, "--plugin-dir")
      table.insert(cmd, plugin_dir)
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
      "vibing-nvim MCP tools may be registered as mcp__vibing-nvim__<tool> (a plain user-level MCP "
        .. "server) or mcp__plugin_<marketplace>_vibing-nvim__<tool> (a Claude Code plugin) — search "
        .. "for a tool name ending in the specific tool you need if the plain prefix isn't available."
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
          .. ". You MUST pass this exact value as the rpc_port argument on every vibing-nvim MCP tool "
          .. "call — never omit it or guess, since other unrelated Neovim instances may be running and "
          .. "reachable on other ports. A subagent does not inherit this system prompt, so when you "
          .. "delegate work that will touch Neovim, state the rpc_port in the task prompt you hand it."
      )
    end

    -- Constant for this buffer's whole life, so it does not churn the cached prefix across the
    -- buffer's own turns (#469). Switching between the parent chat and this one still re-diverges
    -- the shared session's cache — unavoidable while both resume one session_id.
    if opts._subagent_id then
      table.insert(
        system_prompt_lines,
        string.format(
          "This chat buffer is bound to subagent %s. For every user message here, relay it by "
            .. "calling the SendMessage tool with to: '%s' and a 5-10 word summary, then report "
            .. "what that agent answered. Do not answer in its place.",
          opts._subagent_id,
          opts._subagent_id
        )
      )
    end

    -- Buffer number, not file path: it survives a rename, keeping this prefix byte-stable (#489).
    if opts.chat_bufnr then
      table.insert(system_prompt_lines, "Current vibing.nvim chat buffer number: " .. tostring(opts.chat_bufnr))
    end

    -- Which chat dispatched this one, taken from the `orchestrated_by` frontmatter list.
    --
    -- The **path** is what the model is told to address, because that is the only form that
    -- survives a Neovim restart: a bufnr from a previous session points at some unrelated buffer,
    -- so a worker resumed the next morning could never reach its orchestrator again (#641). The
    -- bufnr is appended as the current resolution only, and a worker whose orchestrator is closed
    -- still gets the line — `nvim_chat_send_message` opens the chat file itself.
    --
    -- The frontmatter is written once at creation, so in the ordinary case the line stays
    -- byte-stable across turns and the cached system prefix (#469) survives. It is not a
    -- guarantee, and the bufnr half is the weaker one: closing or reopening the orchestrator
    -- changes it, as does `:VibingSetFileTitle` renaming the orchestrator (which moves the path
    -- too, via `OrchestrationChatScanner`). Each costs one cache miss.
    --
    -- `orchestrated` is deliberately not exposed: an orchestrator's list grows with every
    -- dispatch, so it would move the prefix on a normal turn rather than an unusual one — and the
    -- completion notification already names the chat it wants read.
    if opts.orchestrators and #opts.orchestrators > 0 then
      local named = vim.tbl_map(function(orchestrator)
        return orchestrator.bufnr
            and string.format("%s (currently buffer %d)", orchestrator.path, orchestrator.bufnr)
          or orchestrator.path
      end, opts.orchestrators)
      table.insert(
        system_prompt_lines,
        "This chat was started by vibing.nvim chat "
          .. table.concat(named, ", ")
          .. ". If you need to ask it something, or want to report back before you finish, call "
          .. "nvim_chat_send_message with that file_path and your own chat buffer number as "
          .. "from_bufnr. Address it by file_path rather than by buffer number: the path keeps "
          .. "working after a restart, and the chat is opened for you if it is closed. "
          .. "Otherwise just do the work and report in this chat — it is told when you stop."
      )
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

  local language_instruction = CommonBuilder.language_instruction(opts, config)
  if language_instruction then
    table.insert(system_prompt_lines, 1, language_instruction)
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
    table.insert(cmd, table.concat(M.resolve_setting_sources(config), ","))
  end

  -- Build prompt with context prefix (only for new sessions, not resume)
  local full_prompt = prompt
  if not session_id then
    local context_prefix = CommonBuilder.context_prefix(opts)
    full_prompt = context_prefix .. prompt
  end

  -- End of options marker (prevents prompt starting with --- being parsed as flags)
  table.insert(cmd, "--")
  table.insert(cmd, full_prompt)

  return cmd
end

return M
