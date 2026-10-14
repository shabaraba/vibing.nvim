--- The copilot stream processor: `decoders/copilot_json.lua` behind the shared renderer, with
--- copilot's tool vocabulary so names render as the permission rules spell them.
--- @module vibing.infrastructure.adapter.modules.copilot_event_processor

return require("vibing.infrastructure.adapter.modules.stream_decoder").processor(
  require("vibing.infrastructure.adapter.decoders.copilot_json"),
  require("vibing.infrastructure.adapter.modules.copilot_tool_vocabulary")
)
