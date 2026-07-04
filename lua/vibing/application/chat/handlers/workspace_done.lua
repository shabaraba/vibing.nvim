local notify = require("vibing.core.utils.notify")
local Manager = require("vibing.infrastructure.workspace.manager")
local ChatBinding = require("vibing.infrastructure.workspace.chat_binding")

---@param workspace_id string
---@param ws table
local function finish(workspace_id, ws)
  local ok, err = Manager.remove_worktree(workspace_id)
  if not ok then
    notify.error("Failed to remove worktree (see git output below):\n" .. tostring(err), "Workspace")
    return
  end

  local moved, move_err = Manager.move_to_done(workspace_id)
  if not moved then
    notify.error("Worktree removed, but failed to move workspace to done: " .. tostring(move_err), "Workspace")
    return
  end

  notify.info(string.format("Workspace done: %s", workspace_id), "Workspace")
end

---@param workspace_id string
---@param ws table
local function confirm_and_finish(workspace_id, ws)
  local warnings = {}

  if Manager.plan_has_incomplete_todos(ws.plan_path) then
    table.insert(warnings, "plan.md still has unchecked TODO items.")
  end
  if not Manager.is_branch_merged(ws.branch or "") then
    table.insert(warnings, "The branch does not appear to be merged yet.")
  end

  if #warnings == 0 then
    finish(workspace_id, ws)
    return
  end

  vim.ui.select({ "Yes", "No" }, {
    prompt = table.concat(warnings, " ") .. " Finish this workspace anyway?",
  }, function(choice)
    if choice == "Yes" then
      finish(workspace_id, ws)
    else
      notify.info("Cancelled", "Workspace")
    end
  end)
end

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  local workspace_id = args[1]
  if not workspace_id or workspace_id == "" then
    if not chat_buffer then
      notify.error("No chat buffer and no workspace_id given")
      return true
    end
    workspace_id = ChatBinding.get_workspace_id(chat_buffer)
  end

  if not workspace_id then
    notify.warn("This chat is not bound to a workspace. Usage: /vibing-workspace-done <workspace_id>", "Workspace")
    return true
  end

  local ws = Manager.get(workspace_id)
  if not ws or ws.status ~= "active" then
    notify.error("No active workspace found: " .. tostring(workspace_id), "Workspace")
    return true
  end

  -- branch is not part of Manager.get's return; read it from meta.yaml
  local Meta = require("vibing.infrastructure.workspace.meta")
  local data = Meta.read(ws.meta_path)
  ws.branch = data and data.branch

  confirm_and_finish(workspace_id, ws)
  return true
end
