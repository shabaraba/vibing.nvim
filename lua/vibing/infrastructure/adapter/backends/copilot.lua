--- The GitHub Copilot CLI, spawned as `copilot -p --output-format json`.
--- @module vibing.infrastructure.adapter.backends.copilot

local CopilotCommandBuilder = require("vibing.infrastructure.adapter.modules.copilot_command_builder")
local CopilotEventProcessor = require("vibing.infrastructure.adapter.modules.copilot_event_processor")
local ToolVocabulary = require("vibing.infrastructure.adapter.modules.copilot_tool_vocabulary")

---@type Vibing.BackendDescriptor
local M = {
  id = "copilot",

  features = {
    streaming = true,
    tools = true,
    model_selection = true,
    context = true,
    session = true,
    dynamic_permissions = true,
  },

  build = CopilotCommandBuilder.build,
  event_processor = CopilotEventProcessor,

  -- A throwaway plugin under `.vibing/copilot-plugin/`, loaded with `--plugin-dir`, in copilot's
  -- flat decision dialect. This is what gives copilot `permission_mode`, the `ask` list and the
  -- Tool Approval UI (#512); a failed install degrades to the static --deny-tool flags.
  -- bypassPermissions asked for no gate at all, so it gets none.
  hook = { transport = "plugin_dir", dialect = "copilot", keep_in_bypass = false },

  vocabulary = ToolVocabulary,
  register_chat_bufnr = false,
  stdin = "",
}

return M
