--- Pi coding agent adapter.
---
--- Compatibility shim: the adapter itself is `cli_adapter.lua`, driven by the descriptor in
--- `backends/pi.lua` (ADR 009). `core/constants/agents.lua` names this module as `adapter_module`
--- and `infrastructure/init.lua` exports what it returns.
--- @module vibing.infrastructure.adapter.pi_cli

return require("vibing.infrastructure.adapter.cli_adapter").define(require("vibing.infrastructure.adapter.backends.pi"))
