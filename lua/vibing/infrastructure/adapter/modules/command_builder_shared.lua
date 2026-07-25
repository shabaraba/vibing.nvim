--- Shared helpers reused across the claude/codex/grok CLI command builders
--- @module vibing.infrastructure.adapter.modules.command_builder_shared

local Modes = require("vibing.core.constants.modes")
local worktree_constants = require("vibing.core.constants.worktree")

local M = {}

--- Resolve language setting from opts or config
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
function M.resolve_language(opts, config)
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

--- Build context prefix from `@file:` entries
--- @param opts Vibing.AdapterOpts
--- @return string context_prefix Empty string if no context
function M.build_context_prefix(opts)
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

--- Resolve model name, filtering out Claude-specific shortcut names (opus/sonnet/haiku/fable).
--- Used by adapters with their own separate model catalog (codex, grok), which must not forward
--- a Claude shortcut as their own `--model` value.
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
function M.resolve_non_claude_model(opts, config)
  local model = opts.model or (config.agent and config.agent.default_model)
  if model and Modes.is_valid_model(model) then
    return nil
  end
  return model
end

--- Build the shared system-prompt lines: worktree convention, nvim_ask_user_question
--- instruction, handle_id echo-back, rpc_port echo-back, chat buffer path, and language prefix.
--- Used by adapters that inject these as a single joined block (claude via
--- `--append-system-prompt`, grok via `--rules`).
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @param handle_id string|nil
--- @param rpc_port number|nil
--- @return string[] lines
function M.build_system_prompt_lines(opts, config, handle_id, rpc_port)
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

  local language = M.resolve_language(opts, config)
  if language and language ~= "en" then
    local language_utils = require("vibing.core.utils.language")
    local lang_name = language_utils.language_names[language]
    if lang_name then
      table.insert(lines, 1, string.format("Always respond in %s (%s).", lang_name, language))
    end
  end

  return lines
end

return M
