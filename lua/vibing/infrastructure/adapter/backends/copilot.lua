--- The GitHub Copilot CLI, spawned as `copilot -p --output-format json`.
--- @module vibing.infrastructure.adapter.backends.copilot

local CopilotCommandBuilder = require("vibing.infrastructure.adapter.modules.copilot_command_builder")
local CopilotEventProcessor = require("vibing.infrastructure.adapter.modules.copilot_event_processor")
local CopilotSettingsGenerator = require("vibing.infrastructure.hooks.copilot_settings_generator")
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

  -- Generates the throwaway copilot plugin that registers bin/hooks/pre-tool-use.sh, loaded with
  -- --plugin-dir. This is what gives copilot `permission_mode`, the `ask` list and the Tool
  -- Approval UI (#512); a failure here degrades to the static --deny-tool flags rather than
  -- taking the turn down with it. bypassPermissions asked for no gate at all, so it gets none,
  -- and a lightweight call registers no hooks by contract (`core/types.lua`).
  prepare_hook = function(cwd, opts)
    local permission_mode = opts.permission_mode or "default"
    if permission_mode == "bypassPermissions" or opts.lightweight then
      return nil
    end
    local ok, dir_or_err = pcall(CopilotSettingsGenerator.ensure, cwd)
    if ok then
      return dir_or_err
    end
    vim.notify(
      string.format("[vibing:copilot] Failed to install preToolUse hook: %s", tostring(dir_or_err)),
      vim.log.levels.WARN
    )
    return nil
  end,

  vocabulary = ToolVocabulary,
  register_chat_bufnr = false,
  stdin = "",
}

return M
