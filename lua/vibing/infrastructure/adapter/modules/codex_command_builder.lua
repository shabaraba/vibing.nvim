--- Codex CLI command builder for `codex exec --json` execution
--- Builds the command array for the Codex CLI with JSONL output
--- @module vibing.infrastructure.adapter.modules.codex_command_builder

local Shared = require("vibing.infrastructure.adapter.modules.command_builder_shared")

local M = {}

local cached_codex_path = nil

--- Map vibing permission mode to codex sandbox flag
--- @param permission_mode string|nil
--- @return string|nil sandbox flag value, or nil for default
local function resolve_sandbox(permission_mode)
  if permission_mode == "plan" then
    return "read-only"
  end
  if permission_mode == "bypassPermissions" then
    return nil -- use --dangerously-bypass flag instead
  end
  return "workspace-write"
end

--- Build the `codex exec --json` command array
--- @param prompt string User prompt
--- @param opts Vibing.AdapterOpts Adapter options
--- @param session_id string|nil Thread ID for session resumption
--- @param config Vibing.Config Plugin config
--- @param hook_args string[]|nil Optional -c flag pair for PreToolUse hook injection
--- @return string[] Command array for vim.system()
function M.build(prompt, opts, session_id, config, hook_args)
  if not cached_codex_path then
    cached_codex_path = vim.fn.exepath("codex")
    if cached_codex_path == "" then
      cached_codex_path = nil
      error("Codex CLI not found in PATH. Please install codex-cli.")
    end
  end

  local cmd = { cached_codex_path, "exec" }

  if session_id then
    table.insert(cmd, "resume")
    table.insert(cmd, session_id)
  end

  table.insert(cmd, "--json")

  -- Hook injection for permission control
  if hook_args then
    for _, arg in ipairs(hook_args) do
      table.insert(cmd, arg)
    end
  end

  -- Model selection
  local model = Shared.resolve_non_claude_model(opts, config)
  if model then
    table.insert(cmd, "-m")
    table.insert(cmd, model)
  end

  -- Permission mapping (only for new sessions; resume does not accept -s)
  if not session_id then
    local permission_mode = opts.permission_mode
    if permission_mode == "bypassPermissions" then
      table.insert(cmd, "--dangerously-bypass-approvals-and-sandbox")
    else
      local sandbox = resolve_sandbox(permission_mode)
      if sandbox then
        table.insert(cmd, "-s")
        table.insert(cmd, sandbox)
      end
    end
  end

  -- Build prompt with context prefix and language instruction
  local full_prompt = prompt
  if not session_id then
    local context_prefix = Shared.build_context_prefix(opts)
    full_prompt = context_prefix .. prompt
  end

  local language = Shared.resolve_language(opts, config)
  if language and language ~= "en" then
    local language_utils = require("vibing.core.utils.language")
    local lang_name = language_utils.language_names[language]
    if lang_name then
      full_prompt = string.format("Always respond in %s (%s).\n\n%s", lang_name, language, full_prompt)
    end
  end

  table.insert(cmd, full_prompt)

  return cmd
end

return M
