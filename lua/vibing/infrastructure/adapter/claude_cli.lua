--- Compatibility entry point for the claude backend.
---
--- The adapter itself is `cli_adapter.lua` driven by `backends/claude.lua` (ADR 009); this module
--- only keeps the historical require path and export name working.
--- @module vibing.infrastructure.adapter.claude_cli

return require("vibing.infrastructure.adapter.cli_adapter").define(
  require("vibing.infrastructure.adapter.backends.claude")
)
