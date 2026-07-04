local notify = require("vibing.core.utils.notify")
local Manager = require("vibing.infrastructure.workspace.manager")
local WorkspaceGenerator = require("vibing.core.utils.workspace_generator")
local Meta = require("vibing.infrastructure.workspace.meta")
local Git = require("vibing.core.utils.git")
local ChatBinding = require("vibing.infrastructure.workspace.chat_binding")

---@param chat_buffer Vibing.ChatBuffer
---@param lines string[]
local function append_to_buffer(chat_buffer, lines)
  local buf = chat_buffer.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, lines)
end

---@param chat_buffer Vibing.ChatBuffer
---@param generated {description: string, branch: string}
local function confirm_and_create(chat_buffer, generated)
  vim.ui.input({ prompt = "Workspace description: ", default = generated.description }, function(description)
    if not description or vim.trim(description) == "" then
      notify.warn("Workspace creation cancelled")
      return
    end

    vim.ui.input({ prompt = "Branch name: ", default = generated.branch }, function(branch)
      branch = branch and WorkspaceGenerator.sanitize_branch(branch) or ""
      if branch == "" then
        notify.warn("Workspace creation cancelled")
        return
      end

      local ws, err = Manager.create(branch, description)
      if not ws then
        notify.error("Failed to create workspace: " .. tostring(err), "Workspace")
        return
      end

      local working_dir = Git.get_relative_path(ws.worktree_path)
      chat_buffer:update_frontmatter("workspace_id", ws.id, false)
      if working_dir then
        chat_buffer:update_frontmatter("working_dir", working_dir, false)
      else
        notify.warn(
          string.format(
            "Could not determine working_dir for workspace %s. Please check the workspace directory manually: %s",
            ws.id,
            ws.worktree_path
          ),
          "Workspace"
        )
      end

      if chat_buffer.file_path then
        local ok, meta_err = Meta.add_chat_file(ws.meta_path, Git.to_display_path(chat_buffer.file_path))
        if not ok then
          notify.warn(
            string.format("Failed to register chat file in workspace metadata: %s", tostring(meta_err)),
            "Workspace"
          )
        end
      end

      append_to_buffer(chat_buffer, {
        "",
        string.format("Workspace `%s` created at `%s`.", ws.id, ws.dir),
        "",
      })

      notify.info(string.format("Workspace ready: %s", ws.id), "Workspace")
    end)
  end)
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
      string.format("This chat is already bound to workspace %s. Open a new chat to start another workspace.", bound),
      "Workspace"
    )
    return true
  end

  local raw_input
  if #args > 0 then
    raw_input = table.concat(args, " ")
  else
    local conversation = chat_buffer:extract_conversation()
    if #conversation == 0 then
      notify.warn(
        "Describe the task in chat first, or run /vibing-workspace-create <description>",
        "Workspace"
      )
      return true
    end
    local texts = {}
    for _, msg in ipairs(conversation) do
      table.insert(texts, string.format("[%s]: %s", msg.role, msg.content))
    end
    raw_input = table.concat(texts, "\n\n")
  end

  WorkspaceGenerator.generate(raw_input, function(generated, err)
    if err then
      notify.error("Failed to generate workspace name: " .. err, "Workspace")
      return
    end
    confirm_and_create(chat_buffer, generated)
  end)

  return true
end
