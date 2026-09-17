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

  -- `copilot -p --output-format json`, prompt last.
  request = {
    binary = CopilotCommandBuilder.BINARY,
    parts = {
      { kind = "args", "--output-format", "json", "--stream", "on", "--no-color" },
      { kind = "resume", flag_eq = "--resume=" },
      { kind = "model", flag = "--model", names = "native" },
      vim.tbl_extend("force", { kind = "args", when = "lightweight" }, CopilotCommandBuilder.LIGHTWEIGHT_ARGS),
      -- Reads the generated hook plugin dir from `hook_arg` and adds the static deny backstop.
      { kind = "extra", fn = CopilotCommandBuilder.permission_args, unless = "lightweight" },
      -- Copilot takes no system prompt, so the language sentence rides on the prompt.
      { kind = "prompt", flag = "-p", language_prefix = true },
    },
  },
  build = CopilotCommandBuilder.build,
  event_processor = CopilotEventProcessor,

  -- A throwaway plugin under `.vibing/copilot-plugin/`, loaded with `--plugin-dir`, in copilot's
  -- flat decision dialect. This is what gives copilot `permission_mode`, the `ask` list and the
  -- Tool Approval UI (#512); a failed install degrades to the static --deny-tool flags.
  -- bypassPermissions asked for no gate at all, so it gets none.
  -- 1700s: the hook ran its full 1700s budget and exited on its own, never cut
  -- (`HOOK FINISHED NORMALLY after 1700s`), independently confirmed by a 950s run. Still a floor,
  -- for the opposite reason to claude's: nothing here says copilot would have stopped afterwards.
  -- An earlier 670s reading was a log read while the run was still going.
  hook = {
    transport = "plugin_dir",
    dialect = "copilot",
    keep_in_bypass = false,
    measured_wait_floor_sec = 1700,
  },

  vocabulary = ToolVocabulary,
  register_chat_bufnr = false,
  stdin = "",
}

return M
