--- Grok CLI command builder for `grok -p` / `--single` execution
--- Builds the command array for the Grok Build CLI with streaming JSON output
--- @module vibing.infrastructure.adapter.modules.grok_command_builder

local Modes = require("vibing.core.constants.modes")
local worktree_constants = require("vibing.core.constants.worktree")

local M = {}

local cached_grok_path = nil
local verified_official = false

--- Resolve model name from opts or config
--- Filters out Claude-specific model names (sonnet/opus/haiku/fable) as grok uses its own models
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
local function resolve_model(opts, config)
  local model = opts.model or (config.agent and config.agent.default_model)
  if model and Modes.is_valid_model(model) then
    return nil
  end
  return model
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

--- Build context prefix for the prompt
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

--- Build the `--rules` value (extra rules appended to the system prompt)
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @param handle_id string|nil
--- @param rpc_port number|nil
--- @return string
local function build_rules(opts, config, handle_id, rpc_port)
  local lines = {
    "When creating a git worktree for isolated work, place it under "
      .. worktree_constants.DIR
      .. "<branch-name>/ at the repository root.",
    "When you need the user to choose among options (single or multi-select), always call the "
      .. "mcp__vibing-nvim__nvim_ask_user_question tool instead of asking in free text. Do not use "
      .. "the native AskUserQuestion tool for this — it is unavailable in this environment.",
  }

  if handle_id then
    table.insert(
      lines,
      'Your handle_id for this turn is "'
        .. handle_id
        .. '". When calling mcp__vibing-nvim__nvim_ask_user_question, you MUST pass this exact '
        .. "value as the handle_id argument."
    )
  end

  if rpc_port then
    table.insert(
      lines,
      "Your rpc_port for this turn is "
        .. tostring(rpc_port)
        .. ". You MUST pass this exact value as the rpc_port argument on every "
        .. "mcp__vibing-nvim__* tool call — never omit it or guess, since other unrelated Neovim "
        .. "instances may be running and reachable on other ports."
    )
  end

  if opts.chat_file_path and opts.chat_file_path ~= "" then
    table.insert(lines, "Current vibing.nvim chat buffer file: " .. opts.chat_file_path)
  end

  local language = resolve_language(opts, config)
  if language and language ~= "en" then
    local language_utils = require("vibing.core.utils.language")
    local lang_name = language_utils.language_names[language]
    if lang_name then
      table.insert(lines, 1, string.format("Always respond in %s (%s).", lang_name, language))
    end
  end

  return table.concat(lines, "\n")
end

--- Detect the official xAI Grok Build CLI (not community grok-dev)
--- @param path string
local function ensure_official_grok(path)
  if verified_official then
    return
  end
  -- Unit tests mock exepath to a non-executable path; skip sniff in that case
  if vim.fn.executable(path) == 0 then
    return
  end

  local version = vim.fn.system({ path, "--version" })
  -- Official: "grok 0.2.101 (5bc4b5dfadcf) [stable]"
  if type(version) == "string" and version:match("^grok%s+%d+%.%d+") then
    verified_official = true
    return
  end

  local help = vim.fn.system({ path, "--help" })
  if type(help) == "string" and help:find("streaming%-json") then
    verified_official = true
    return
  end

  error(
    "Found a 'grok' binary that does not appear to be the official xAI Grok Build CLI. "
      .. "Install from https://x.ai/cli or set config.grok.executable to the official binary path."
  )
end

--- Resolve path to the grok binary
--- @param config Vibing.Config
--- @return string
local function resolve_grok_path(config)
  if cached_grok_path then
    return cached_grok_path
  end

  local configured = config and config.grok and config.grok.executable
  if configured and configured ~= "auto" and configured ~= "" then
    if vim.fn.executable(configured) == 0 then
      error(
        string.format(
          "Grok CLI not found at configured path '%s'. Install the official xAI Grok Build CLI.",
          configured
        )
      )
    end
    cached_grok_path = configured
  else
    local found = vim.fn.exepath("grok")
    if found == "" then
      error(
        "Grok CLI not found in PATH. Install the official xAI Grok Build CLI "
          .. "(curl -fsSL https://x.ai/cli/install.sh | bash) or set config.grok.executable."
      )
    end
    cached_grok_path = found
  end

  ensure_official_grok(cached_grok_path)
  return cached_grok_path
end

--- Build the `grok -p` (headless single-turn) CLI command array
--- Uses `--single=<value>` (one argv token) rather than `-p <value>` so hyphen-leading
--- prompts are not misparsed as flags by clap.
--- @param prompt string User prompt
--- @param opts Vibing.AdapterOpts Adapter options
--- @param session_id string|nil Session ID for resumption
--- @param config Vibing.Config Plugin config
--- @param handle_id string|nil This turn's stream handle id
--- @param rpc_port number|nil This Neovim instance's RPC server port
--- @return string[] Command array for vim.system()
function M.build(prompt, opts, session_id, config, handle_id, rpc_port)
  opts = opts or {}
  config = config or {}

  local grok_path = resolve_grok_path(config)

  local full_prompt = prompt
  if not session_id then
    full_prompt = build_context_prefix(opts) .. prompt
  end

  local cmd = { grok_path }

  table.insert(cmd, "--single=" .. full_prompt)
  table.insert(cmd, "--output-format")
  table.insert(cmd, "streaming-json")

  local model = resolve_model(opts, config)
  if model then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end

  if session_id then
    table.insert(cmd, "--resume")
    table.insert(cmd, session_id)
    if opts._is_fork then
      table.insert(cmd, "--fork-session")
    end
  end

  -- vibing permission_mode values map 1:1 onto Grok's --permission-mode enum
  if opts.permission_mode then
    table.insert(cmd, "--permission-mode")
    table.insert(cmd, opts.permission_mode)
  end

  if opts.cwd and opts.cwd ~= "" then
    table.insert(cmd, "--cwd")
    table.insert(cmd, opts.cwd)
  end

  table.insert(cmd, "--rules")
  table.insert(cmd, build_rules(opts, config, handle_id, rpc_port))

  return cmd
end

return M
