--- Reasoning-effort resolution shared by CLI backends.
---
--- A chat stores one backend-neutral `effort` value in its frontmatter. Each command builder
--- translates that value into its CLI's own argv/config spelling; this module keeps precedence
--- and validation identical across those builders.
---
--- @module vibing.infrastructure.adapter.modules.reasoning_effort

local Modes = require("vibing.core.constants.modes")

local M = {}

--- Resolve the reasoning effort for this call, or nil to let the selected CLI use its own default.
--- Lightweight calls use `utility_effort` instead of inheriting the chat's value, just as they use
--- `utility_model` instead of the chat's model.
---
--- Invalid values are dropped with a warning. Some CLIs accept an unknown level and silently
--- ignore it, which would otherwise make a frontmatter typo look as though it had taken effect.
---
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
function M.resolve(opts, config)
  opts = opts or {}
  config = config or {}

  local agent = config.agent or {}
  local effort
  if opts.lightweight then
    effort = agent.utility_effort
  else
    effort = opts.effort or agent.default_effort
  end

  if effort == nil then
    return nil
  end

  -- `default` makes the legacy "no effort setting" behaviour visible in frontmatter without
  -- freezing a backend/model-specific default into vibing.nvim.
  if effort == Modes.DEFAULT_EFFORT then
    return nil
  end

  if not Modes.is_valid_effort(effort) then
    require("vibing.core.utils.notify").warn(
      string.format("Ignoring unknown effort %s (valid: %s)", tostring(effort), table.concat(Modes.EFFORT_VALUES, ", "))
    )
    return nil
  end

  return effort
end

return M
