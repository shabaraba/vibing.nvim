--- Resolve Codex's model and effort once per turn, for both exec and app-server.
--- A chat's explicit `default` bypasses agent defaults; an absent field does not.
local NonClaudeModel = require("vibing.infrastructure.adapter.modules.non_claude_model")
local ReasoningEffort = require("vibing.infrastructure.adapter.modules.reasoning_effort")

local M = {}

function M.resolve(opts, config)
  opts, config = opts or {}, config or {}
  local model
  if opts.model ~= "default" or opts.lightweight then
    model = NonClaudeModel.resolve(opts, config)
  end
  if model == "default" then
    model = nil
  end
  return { model = model, effort = ReasoningEffort.resolve(opts, config) }
end

--- Values read from the app-server before it opens a thread. Missing turn/start fields retain
--- the previous turn's values, so resetting requires explicit values from this baseline.
function M.defaults(config_result, model_result)
  local codex_config = (config_result or {}).config or {}
  local function nonempty(value)
    return type(value) == "string" and value ~= "" and value or nil
  end
  local catalog = {}
  local default_model
  for _, entry in ipairs((model_result or {}).data or {}) do
    if type(entry.model) == "string" then
      catalog[entry.model] = nonempty(entry.defaultReasoningEffort)
      if entry.isDefault then
        default_model = entry.model
      end
    end
  end
  local model = nonempty(codex_config.model) or default_model
  if not model then
    return nil, "Codex did not report a default model."
  end
  local configured_effort = nonempty(codex_config.model_reasoning_effort)
  local effort = configured_effort or catalog[model]
  return { model = model, effort = effort, configured_effort = configured_effort, catalog = catalog }
end

function M.for_turn(selection, defaults, previous)
  local model = selection.model or defaults.model
  local effort = selection.effort or defaults.configured_effort or defaults.catalog[model]
  if not effort and model == defaults.model then
    effort = defaults.effort
  end
  -- Custom providers may omit reasoning defaults altogether. A fresh thread can let Codex
  -- choose, but omission cannot clear an effort already applied to this resident thread.
  if not effort and previous and (previous.effort or (previous.model and previous.model ~= model)) then
    return nil, "Codex did not report a default reasoning effort for " .. model
      .. "; set effort explicitly to avoid retaining the previous turn's value."
  end
  return { model = model, effort = effort }
end

return M
