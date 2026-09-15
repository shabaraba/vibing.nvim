--- Compatibility entry point for the codex backend.
---
--- The adapter itself is `cli_adapter.lua` driven by `backends/codex.lua` (ADR 009); this module
--- only keeps the historical require path and export name working.
--- @module vibing.infrastructure.adapter.codex_cli

return require("vibing.infrastructure.adapter.cli_adapter").define(
  require("vibing.infrastructure.adapter.backends.codex")
)
