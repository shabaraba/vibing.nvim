--- The OpenCode stream processor: `decoders/opencode_json.lua` behind the shared renderer.
--- @module vibing.infrastructure.adapter.modules.opencode_event_processor

return require("vibing.infrastructure.adapter.modules.stream_decoder").processor(
  require("vibing.infrastructure.adapter.decoders.opencode_json"),
  require("vibing.infrastructure.adapter.modules.opencode_tool_vocabulary")
)
