--- The Pi stream processor: `decoders/pi_json.lua` behind the shared renderer.
--- @module vibing.infrastructure.adapter.modules.pi_event_processor

return require("vibing.infrastructure.adapter.modules.stream_decoder").processor(
  require("vibing.infrastructure.adapter.decoders.pi_json"),
  require("vibing.infrastructure.adapter.modules.pi_tool_vocabulary")
)
