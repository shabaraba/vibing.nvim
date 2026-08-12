local notify = require("vibing.core.utils.notify")
local Modes = require("vibing.core.constants.modes")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if #args == 0 then
    notify.warn("/effort <" .. table.concat(Modes.EFFORT_LEVELS, "|") .. ">", "Usage")
    return false
  end

  local effort = args[1]

  if not Modes.is_valid_effort(effort) then
    notify.error(string.format("Invalid effort: %s (valid: %s)", effort, table.concat(Modes.EFFORT_LEVELS, ", ")))
    return false
  end

  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  local success = chat_buffer:update_frontmatter("effort", effort)
  if not success then
    notify.error("Failed to update frontmatter")
    return false
  end

  notify.info(string.format("Effort set to: %s", effort))
  return true
end
