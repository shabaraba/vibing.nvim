--- Model resolution for the backends that do not speak Claude's model names.
---
--- codex, copilot and grok each carried a byte-identical copy of this. Only one of them was
--- updated when #537 taught it about `lightweight`, which is how the same bug stayed live on the
--- other two: their utility calls kept using `default_model` and never `utility_model`. One copy
--- means the next backend inherits the behaviour instead of a fourth transcription of it.
---
--- @module vibing.infrastructure.adapter.modules.non_claude_model

local Modes = require("vibing.core.constants.modes")

local M = {}

--- Resolve the model to pass on the command line, or nil to let the CLI pick its own.
---
--- Claude's short names (sonnet/opus/haiku/fable) are filtered out rather than forwarded: these
--- backends have their own model catalogues and would reject them. That is also what makes the
--- lightweight branch safe -- `utility_model` defaults to `sonnet`, so on these backends it
--- resolves to nil and the CLI's own default applies.
---
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
function M.resolve(opts, config)
  local agent = config.agent or {}
  local model
  if opts.lightweight then
    model = agent.utility_model
  else
    model = opts.model or agent.default_model
  end

  if model and Modes.is_valid_model(model) then
    return nil
  end
  return model
end

return M
