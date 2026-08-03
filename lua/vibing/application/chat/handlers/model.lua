local notify = require("vibing.core.utils.notify")
local Modes = require("vibing.core.constants.modes")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if #args == 0 then
    notify.warn("/model <model>", "Usage")
    return false
  end

  local model = args[1]

  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  local frontmatter = chat_buffer:parse_frontmatter() or {}
  local agent = frontmatter.agent
  if not agent or agent == "" then
    local cfg = require("vibing").get_config()
    agent = (cfg and cfg.adapter) or "claude"
  end

  if not Modes.is_allowed_model_for_agent(model, agent) then
    if agent == "claude" then
      notify.error(
        string.format("Invalid model: %s (valid: %s)", model, table.concat(Modes.VALID_MODELS, ", "))
      )
    else
      notify.error(string.format("Invalid model: %s", model))
    end
    return false
  end

  local success = chat_buffer:update_frontmatter("model", model)
  if not success then
    notify.error("Failed to update frontmatter")
    return false
  end

  notify.info(string.format("Model set to: %s (agent: %s)", model, agent))
  return true
end
