--- The OpenCode CLI, spawned as `opencode run --standalone --format json`.
--- @module vibing.infrastructure.adapter.backends.opencode

local OpencodeCommandBuilder = require("vibing.infrastructure.adapter.modules.opencode_command_builder")
local OpencodeEventProcessor = require("vibing.infrastructure.adapter.modules.opencode_event_processor")
local ToolVocabulary = require("vibing.infrastructure.adapter.modules.opencode_tool_vocabulary")

---@type Vibing.BackendDescriptor
local M = {
  id = "opencode",
  process = "duplex",
  duplex = require("vibing.infrastructure.adapter.modules.opencode_duplex_protocol"),

  features = {
    streaming = true,
    tools = true,
    model_selection = true,
    context = true,
    session = true,
    dynamic_permissions = true,
    structured_output = false,
  },

  request = {
    agent_id = "opencode",
    binary = OpencodeCommandBuilder.BINARY,
    parts = {
      { kind = "args", "run", unless = "duplex" },
      { kind = "args", "acp", when = "duplex" },
      { kind = "args", "--standalone" },
      { kind = "args", "--format", "json", unless = "duplex" },
      { kind = "extra", fn = OpencodeCommandBuilder.agent_args, unless = "duplex" },
      { kind = "extra", fn = OpencodeCommandBuilder.auto_args, unless = "duplex" },
      { kind = "model", flag = "--model", names = "native", unless = "duplex" },
      { kind = "resume", flag = "--session", fork = "--fork", unless = "duplex" },
      { kind = "prompt", terminator = "--", language_prefix = true, unless = "duplex" },
    },
  },
  build = OpencodeCommandBuilder.build,
  event_processor = OpencodeEventProcessor,

  hook = { transport = "env_config", dialect = "claude", keep_in_bypass = true },

  apply_env = OpencodeCommandBuilder.apply_env,

  vocabulary = ToolVocabulary,

  register_chat_bufnr = true,

  stdin = "",
}

return M
