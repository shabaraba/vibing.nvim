local notify = require("vibing.core.utils.notify")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if #args == 0 then
    -- 現在のワークスペースを表示
    if chat_buffer and chat_buffer.workspace_root then
      notify.info(string.format("Current workspace: %s", chat_buffer.workspace_root))
    else
      notify.info("No workspace set (using cwd)")
    end
    return true
  end

  local path = args[1]

  -- パスを展開（~ や . を解決）
  local expanded_path = vim.fn.fnamemodify(path, ":p")
  -- 末尾のスラッシュを削除
  expanded_path = expanded_path:gsub("/$", "")

  -- ディレクトリが存在するか確認
  if vim.fn.isdirectory(expanded_path) ~= 1 then
    notify.error(string.format("Directory does not exist: %s", expanded_path))
    return false
  end

  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  -- ChatBufferのworkspace_rootを更新
  chat_buffer.workspace_root = expanded_path

  -- フロントマターを更新
  local success = chat_buffer:update_frontmatter("workspace_root", expanded_path)
  if not success then
    notify.error("Failed to update frontmatter")
    return false
  end

  notify.info(string.format("Workspace set to: %s", expanded_path))
  return true
end
