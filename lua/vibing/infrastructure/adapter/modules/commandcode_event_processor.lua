--- The Command Code stream processor: `decoders/commandcode_json.lua` behind the shared renderer.
--- @module vibing.infrastructure.adapter.modules.commandcode_event_processor

return require("vibing.infrastructure.adapter.modules.stream_decoder").processor(
  require("vibing.infrastructure.adapter.decoders.commandcode_json"),
  require("vibing.infrastructure.adapter.modules.commandcode_tool_vocabulary")
)
