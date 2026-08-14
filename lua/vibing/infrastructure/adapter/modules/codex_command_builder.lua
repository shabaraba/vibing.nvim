--- Codex CLI command builder for `codex exec --json` execution
--- Builds the command array for the Codex CLI with JSONL output
--- @module vibing.infrastructure.adapter.modules.codex_command_builder

local NonClaudeModel = require("vibing.infrastructure.adapter.modules.non_claude_model")

local M = {}

local cached_codex_path = nil

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

--- Build the `codex exec --json` command array
--- @param prompt string User prompt
--- @param opts Vibing.AdapterOpts Adapter options
--- @param session_id string|nil Thread ID for session resumption
--- @param config Vibing.Config Plugin config
--- @param hook_args string[]|nil Optional -c flag pair for PreToolUse hook injection
--- @return string[] Command array for vim.system()
--- Forget the resolved binary path. Test seam only, same reason as cli_command_builder.
function M._reset_path_cache()
  cached_codex_path = nil
end

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
  local model = NonClaudeModel.resolve(opts, config)
  if model then
    table.insert(cmd, "-m")
    table.insert(cmd, model)
  end

  if opts.lightweight then
    -- Lightweight calls need no tools, but codex has no way to remove them. Probing the config
    -- schema with `--strict-config` (which rejects unknown fields) against codex 0.147:
    -- tools.shell, tools.apply_patch, tools.view_image, tools.plan_tool and tools.mcp are all
    -- "unknown configuration field", and tools.web_search is the only tool toggle that exists.
    -- There is no `--tools ""` equivalent, so the tools cannot be taken away -- only fenced in.
    --
    -- These are `-c` overrides rather than the `-s`/`--sandbox` flag because /summarize passes a
    -- session id, and `codex exec resume` does not accept `-s`. sandbox_mode is what `-s` sets.
    --
    -- This deliberately ignores permission_mode, including bypassPermissions: the user put the
    -- *chat* in that mode, and a title generated behind their back is not the call they made.
    table.insert(cmd, "-c")
    table.insert(cmd, 'sandbox_mode="read-only"')
    table.insert(cmd, "-c")
    table.insert(cmd, "tools.web_search=false")
    -- With the approval prompt unreachable in headless exec, anything that did ask would stall
    -- until the timeout. Verified value: one of untrusted/on-failure/on-request/granular/never.
    table.insert(cmd, "-c")
    table.insert(cmd, 'approval_policy="never"')

  -- Permission mapping (only for new sessions; resume does not accept -s)
  elseif not session_id then
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
    local context_prefix = build_context_prefix(opts)
    full_prompt = context_prefix .. prompt
  end

  local language = resolve_language(opts, config)
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
