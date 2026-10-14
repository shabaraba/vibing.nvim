--- The codex stream processor: `decoders/codex_exec_json.lua` behind the shared renderer, with
--- codex's tool vocabulary so names render as the permission rules spell them.
--- @module vibing.infrastructure.adapter.modules.codex_event_processor

return require("vibing.infrastructure.adapter.modules.stream_decoder").processor(
  require("vibing.infrastructure.adapter.decoders.codex_exec_json"),
  require("vibing.infrastructure.adapter.modules.codex_tool_vocabulary")
)
