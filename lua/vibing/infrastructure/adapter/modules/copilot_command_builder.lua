--- Copilot CLI command builder for `copilot -p --output-format json` execution
--- Builds the command array for the GitHub Copilot CLI with JSONL output
--- @module vibing.infrastructure.adapter.modules.copilot_command_builder

local NonClaudeModel = require("vibing.infrastructure.adapter.modules.non_claude_model")
local CommonBuilder = require("vibing.infrastructure.adapter.modules.command_builder_common")

local M = {}

local ToolVocabulary = require("vibing.infrastructure.adapter.modules.copilot_tool_vocabulary")

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

  local model = NonClaudeModel.resolve(opts, config)
  if model then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end

  append_permission_flags(cmd, opts)

  local full_prompt = prompt
  if not session_id then
    full_prompt = CommonBuilder.context_prefix(opts) .. prompt
  end

  local language_instruction = CommonBuilder.language_instruction(opts, config)
  if language_instruction then
    full_prompt = language_instruction .. "\n\n" .. full_prompt
  end

  table.insert(cmd, "-p")
  table.insert(cmd, full_prompt)

  return cmd
end

return M
