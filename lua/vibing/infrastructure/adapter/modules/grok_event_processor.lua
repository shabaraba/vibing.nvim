--- The grok stream processor: `decoders/grok_streaming_json.lua` behind the shared renderer.
--- @module vibing.infrastructure.adapter.modules.grok_event_processor

return require("vibing.infrastructure.adapter.modules.stream_decoder").processor(
  require("vibing.infrastructure.adapter.decoders.grok_streaming_json"),
  require("vibing.infrastructure.adapter.modules.grok_tool_vocabulary")
)
