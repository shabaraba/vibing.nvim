local notify = require("vibing.core.utils.notify")
local Manager = require("vibing.infrastructure.workspace.manager")
local Meta = require("vibing.infrastructure.workspace.meta")
local Git = require("vibing.core.utils.git")
local ChatBinding = require("vibing.infrastructure.workspace.chat_binding")

---@param chat_buffer Vibing.ChatBuffer
---@param workspace_id string
local function bind_to_workspace(chat_buffer, workspace_id)
  local ws = Manager.get(workspace_id)
  if not ws or ws.status ~= "active" then
    notify.error("No active workspace found: " .. workspace_id, "Workspace")
    return
  end

  local working_dir = Git.get_relative_path(ws.worktree_path)
  chat_buffer:update_frontmatter("workspace_id", ws.id, false)
  if working_dir then
    chat_buffer:update_frontmatter("working_dir", working_dir, false)
  end

  if chat_buffer.file_path then
    Meta.add_chat_file(ws.meta_path, Git.to_display_path(chat_buffer.file_path))
  end

  notify.info(string.format("Entered workspace: %s", ws.id), "Workspace")
end

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if not chat_buffer then
    notify.error("No chat buffer")
    return true
  end

  local bound = ChatBinding.is_bound(chat_buffer)
  if bound then
    notify.error(
      string.format("This chat is already bound to workspace %s. Open a new chat to enter another workspace.", bound),
      "Workspace"
    )
    return true
  end

  if args[1] and args[1] ~= "" then
    bind_to_workspace(chat_buffer, args[1])
    return true
  end

  local active = Manager.list("active")
  if #active == 0 then
    notify.warn("No active workspaces. Run /vibing-workspace-create first.", "Workspace")
    return true
  end

  vim.ui.select(active, {
    prompt = "Select workspace to enter:",
    format_item = function(item)
      return string.format("%s - %s (%s)", item.id, item.description or "", item.branch or "")
    end,
  }, function(choice)
    if choice then
      bind_to_workspace(chat_buffer, choice.id)
    end
  end)

  return true
end
