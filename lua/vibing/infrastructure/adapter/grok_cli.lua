--- Compatibility entry point for the grok backend.
---
--- The adapter itself is `cli_adapter.lua` driven by `backends/grok.lua` (ADR 009); this module
--- only keeps the historical require path and export name working.
--- @module vibing.infrastructure.adapter.grok_cli

return require("vibing.infrastructure.adapter.cli_adapter").define(
  require("vibing.infrastructure.adapter.backends.grok")
)
