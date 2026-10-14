--- Compatibility entry point for the copilot backend.
---
--- The adapter itself is `cli_adapter.lua` driven by `backends/copilot.lua` (ADR 009); this module
--- only keeps the historical require path and export name working.
--- @module vibing.infrastructure.adapter.copilot_cli

return require("vibing.infrastructure.adapter.cli_adapter").define(
  require("vibing.infrastructure.adapter.backends.copilot")
)
