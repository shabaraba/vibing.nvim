local notify = require("vibing.core.utils.notify")

local VALID_MODES = { "default", "acceptEdits", "bypassPermissions" }

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  if #args == 0 then
    local frontmatter = chat_buffer:parse_frontmatter()
    local current = frontmatter.permission_mode or "(using config default)"
    notify.info("Permission mode: " .. current)
    notify.info("Valid modes: " .. table.concat(VALID_MODES, ", "))
    return true
  end

  local mode = args[1]
  local is_valid = false

  for _, valid_mode in ipairs(VALID_MODES) do
    if mode == valid_mode then
      is_valid = true
      break
    end
  end

  if not is_valid then
    notify.error(string.format("Invalid permission mode: %s", mode))
    notify.info("Valid modes: " .. table.concat(VALID_MODES, ", "))
    return false
  end

  local success = chat_buffer:update_frontmatter("permission_mode", mode)
  if not success then
    notify.error("Failed to update frontmatter")
    return false
  end

  notify.info(string.format("Permission mode set to: %s", mode))
  return true
end
