local notify = require("vibing.core.utils.notify")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if #args == 0 then
    notify.warn("/model <model>", "Usage")
    return false
  end

  local model = args[1]
  local valid_models = { "opus", "sonnet", "haiku" }
  local is_valid = false

  for _, valid_model in ipairs(valid_models) do
    if model == valid_model then
      is_valid = true
      break
    end
  end

  if not is_valid then
    notify.error(string.format("Invalid model: %s (valid: opus, sonnet, haiku)", model))
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
