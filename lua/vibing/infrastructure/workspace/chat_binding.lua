local M = {}

--- Returns the workspace_id recorded in this chat buffer's frontmatter, if any.
---@param chat_buffer Vibing.ChatBuffer
---@return string?
function M.get_workspace_id(chat_buffer)
  local frontmatter = chat_buffer:parse_frontmatter()
  local wid = frontmatter and frontmatter.workspace_id
  if type(wid) == "string" and wid ~= "" and wid ~= "~" then
    return wid
  end
  return nil
end

--- Returns the workspace_id this chat buffer is already bound to, if any.
---@param chat_buffer Vibing.ChatBuffer
---@return string?
function M.is_bound(chat_buffer)
  return M.get_workspace_id(chat_buffer)
end

return M
