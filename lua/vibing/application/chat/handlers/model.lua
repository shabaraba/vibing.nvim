local notify = require("vibing.core.utils.notify")
local Agents = require("vibing.core.constants.agents")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if #args == 0 then
    notify.warn("/model <model>", "Usage")
    return false
  end

  local model = args[1]
  if model == "" then
    notify.warn("/model <model>", "Usage")
    return false
  end

  if not vim.tbl_contains(Agents.all_model_values(), model) then
    notify.error(string.format("Invalid model: %s (valid: %s)", model, table.concat(Agents.all_model_values(), ", ")))
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
