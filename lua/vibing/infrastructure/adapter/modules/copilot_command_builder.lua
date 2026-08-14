--- Copilot CLI command builder for `copilot -p --output-format json` execution
--- Builds the command array for the GitHub Copilot CLI with JSONL output
--- @module vibing.infrastructure.adapter.modules.copilot_command_builder

local NonClaudeModel = require("vibing.infrastructure.adapter.modules.non_claude_model")
local CommonBuilder = require("vibing.infrastructure.adapter.modules.command_builder_common")

local binary_path = CommonBuilder.binary_resolver(
  "copilot",
  "Copilot CLI not found in PATH. Please install GitHub Copilot CLI."
)

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
--- Forget the resolved binary path. Test seam only, same reason as the other builders: the
--- cache is process-wide, so a spec exercising the "CLI missing" path has to clear what an
--- earlier spec resolved.
function M._reset_path_cache()
  binary_path.reset()
end

function M.build(prompt, opts, session_id, config)
  local cmd = { binary_path.resolve(), "--output-format", "json", "--stream", "on", "--no-color" }

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
