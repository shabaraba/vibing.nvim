local notify = require("vibing.core.utils.notify")
local tools = require("vibing.constants.tools")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  if #args == 0 then
    local current = chat_buffer:get_frontmatter_list("permissions_ask")
    if #current == 0 then
      notify.info("No tools in ask list")
    else
      notify.info("Ask-required tools: " .. table.concat(current, ", "))
    end
    return true
  end

  local tool = args[1]

  if tool:sub(1, 1) == "-" then
    local tool_name = tool:sub(2)
    local valid_tool = tools.validate_tool(tool_name)
    if not valid_tool then
      notify.error(string.format("Invalid tool: %s", tool_name))
      notify.info("Valid tools: " .. table.concat(tools.VALID_TOOLS, ", "))
      return false
    end

    local success = chat_buffer:update_frontmatter_list("permissions_ask", valid_tool, "remove")
    if success then
      notify.info(string.format("Removed %s from ask list", valid_tool))
    else
      notify.error("Failed to update permissions")
    end
    return success
  end

  local valid_tool = tools.validate_tool(tool)
  if not valid_tool then
    notify.error(string.format("Invalid tool: %s", tool))
    notify.info("Valid tools: " .. table.concat(tools.VALID_TOOLS, ", "))
    return false
  end

  local success = chat_buffer:update_frontmatter_list("permissions_ask", valid_tool, "add")
  if success then
    notify.info(string.format("Added %s to ask list - will require approval before use", valid_tool))
  else
    notify.error("Failed to update permissions")
  end
  return success
end
