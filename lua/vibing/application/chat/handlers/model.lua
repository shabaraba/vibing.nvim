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

  if not Modes.is_valid_model(model) then
    notify.error(string.format("Invalid model: %s (valid: %s)", model, table.concat(Modes.VALID_MODELS, ", ")))
    return false
  end

  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  local success = chat_buffer:update_frontmatter("model", model)
  if not success then
    notify.error("Failed to update frontmatter")
    return false
  end

  notify.info(string.format("Model set to: %s", model))
  return true
end
