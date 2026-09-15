--- The claude stream processor: `decoders/claude_stream_json.lua` behind the shared renderer.
--- Kept under its historical name; the behaviour lives in the decoder and `event_renderer.lua`.
--- @module vibing.infrastructure.adapter.modules.cli_event_processor

return require("vibing.infrastructure.adapter.modules.stream_decoder").processor(
  require("vibing.infrastructure.adapter.decoders.claude_stream_json")
)
