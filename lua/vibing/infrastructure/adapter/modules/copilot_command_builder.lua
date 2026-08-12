--- Copilot CLI command builder for `copilot -p --output-format json` execution
--- Builds the command array for the GitHub Copilot CLI with JSONL output
--- @module vibing.infrastructure.adapter.modules.copilot_command_builder

local Modes = require("vibing.core.constants.modes")

local M = {}

local ToolVocabulary = require("vibing.infrastructure.adapter.modules.copilot_tool_vocabulary")

--- Resolve model name from opts or config
--- Claude short names (sonnet/opus/haiku/fable) are not valid copilot model ids,
--- so they are dropped and copilot's own default is used instead.
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
  local parts = {}
  for _, ctx in ipairs(opts.context or {}) do
    if ctx:match("^@file:") then
      table.insert(parts, string.format("Context file: %s", ctx:sub(7)))
    end
  end
  if #parts == 0 then
    return ""
  end
  return table.concat(parts, "\n") .. "\n\n"
end

--- Append permission flags. copilot's non-interactive mode requires --allow-all-tools,
--- so denies are expressed with --deny-tool rather than an allow list.
--- @param cmd string[]
--- @param opts Vibing.AdapterOpts
local function append_permission_flags(cmd, opts)
  local permission_mode = opts.permission_mode or "default"

  if permission_mode == "bypassPermissions" then
    table.insert(cmd, "--allow-all")
    return
  end

  if permission_mode == "plan" then
    table.insert(cmd, "--plan")
  end
  table.insert(cmd, "--allow-all-tools")

  for _, pattern in ipairs(ToolVocabulary.build_deny_patterns(opts.permissions_deny)) do
    table.insert(cmd, "--deny-tool")
    table.insert(cmd, pattern)
  end
end

--- Build the `copilot -p --output-format json` command array
--- @param prompt string User prompt
--- @param opts Vibing.AdapterOpts Adapter options
--- @param session_id string|nil Session ID for resumption
--- @param config Vibing.Config Plugin config
--- @return string[] Command array for vim.system()
function M.build(prompt, opts, session_id, config)
  local copilot_path = vim.fn.exepath("copilot")
  if copilot_path == "" then
    error("Copilot CLI not found in PATH. Please install GitHub Copilot CLI.")
  end

  local cmd = { copilot_path, "--output-format", "json", "--stream", "on", "--no-color" }

  if session_id then
    table.insert(cmd, "--resume=" .. session_id)
  end

  local model = resolve_model(opts, config)
  if model then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end

  append_permission_flags(cmd, opts)

  local full_prompt = prompt
  if not session_id then
    full_prompt = build_context_prefix(opts) .. prompt
  end

  local language = resolve_language(opts, config)
  if language and language ~= "en" then
    local language_utils = require("vibing.core.utils.language")
    local lang_name = language_utils.language_names[language]
    if lang_name then
      full_prompt = string.format("Always respond in %s (%s).\n\n%s", lang_name, language, full_prompt)
    end
  end

  table.insert(cmd, "-p")
  table.insert(cmd, full_prompt)

  return cmd
end

return M
