local notify = require("vibing.core.utils.notify")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if #args == 0 then
    notify.warn("/mode <mode>", "Usage")
    return false
  end

  local mode = args[1]
  local valid_modes = { "auto", "plan", "code" }
  local is_valid = false

  for _, valid_mode in ipairs(valid_modes) do
    if mode == valid_mode then
      is_valid = true
      break
    end
  end

  if not is_valid then
    notify.error(string.format("Invalid mode: %s (valid: auto, plan, code)", mode))
    return false
  end

  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  local success = chat_buffer:update_frontmatter("mode", mode)
  if not success then
    notify.error("Failed to update frontmatter")
    return false
  end

  notify.info(string.format("Mode set to: %s", mode))
  return true
end
