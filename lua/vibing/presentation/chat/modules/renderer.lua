local Timestamp = require("vibing.core.utils.timestamp")
local Context = require("vibing.context")

local M = {}

---バッファを初期化（フロントマター + 初期コンテンツ）
---@param buf number バッファ番号
---@return number cursor_line カーソル行番号
function M.init_content(buf)
  local vibing = require("vibing")
  local config = vibing.get_config()

  local lines = {
    "---",
    "vibing.nvim: true",
    "session_id: ~",
    "created_at: " .. os.date("%Y-%m-%dT%H:%M:%S"),
  }

  if config.agent then
    if config.agent.default_mode then
      table.insert(lines, "mode: " .. config.agent.default_mode)
    end
    if config.agent.default_model then
      table.insert(lines, "model: " .. config.agent.default_model)
    end
  end

  if config.permissions then
    if config.permissions.mode then
      table.insert(lines, "permission_mode: " .. config.permissions.mode)
    end
    if config.permissions.allow and #config.permissions.allow > 0 then
      table.insert(lines, "permissions_allow:")
      for _, tool in ipairs(config.permissions.allow) do
        table.insert(lines, "  - " .. tool)
      end
    end
    if config.permissions.deny and #config.permissions.deny > 0 then
      table.insert(lines, "permissions_deny:")
      for _, tool in ipairs(config.permissions.deny) do
        table.insert(lines, "  - " .. tool)
      end
    end
    if config.permissions.ask and #config.permissions.ask > 0 then
      table.insert(lines, "permissions_ask:")
      for _, tool in ipairs(config.permissions.ask) do
        table.insert(lines, "  - " .. tool)
      end
    end
  end

  table.insert(lines, "---")
  table.insert(lines, "")
  table.insert(lines, "# Vibing Chat")
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")
  table.insert(lines, Timestamp.create_unsent_user_header())
  table.insert(lines, "")
  table.insert(lines, "")

  local context_text = "Context: " .. Context.format_for_display()
  local context_lines = vim.split(context_text, "\n", { plain = true })
  vim.list_extend(lines, context_lines)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  return #lines - 2
end

---Contextディスプレイを更新
---@param buf number バッファ番号
function M.update_context_line(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local context_text = "Context: " .. Context.format_for_display()
  local context_lines = vim.split(context_text, "\n", { plain = true })

  local context_line_pos = nil
  for i = #lines, 1, -1 do
    if lines[i]:match("^Context:") then
      context_line_pos = i
      break
    end
  end

  if context_line_pos then
    vim.api.nvim_buf_set_lines(buf, context_line_pos - 1, context_line_pos, false, context_lines)
  else
    local new_lines = { "" }
    vim.list_extend(new_lines, context_lines)
    vim.api.nvim_buf_set_lines(buf, #lines, #lines, false, new_lines)
  end
end

---カーソルを末尾に移動
---@param win number ウィンドウ番号
---@param buf number バッファ番号
function M.move_cursor_to_end(win, buf)
  if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count > 0 then
    pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 })
  end
end

---新しいユーザーセクションを追加
---@param buf number バッファ番号
---@param win number? ウィンドウ番号
---@param pending_choices table? 保留中の選択肢
function M.add_user_section(buf, win, pending_choices)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines, #lines)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local new_lines = {
    "",
    Timestamp.create_unsent_user_header(),
    "",
    "",
  }
  vim.api.nvim_buf_set_lines(buf, #lines, #lines, false, new_lines)

  if pending_choices then
    local choice_lines = {}
    for _, q in ipairs(pending_choices) do
      for _, opt in ipairs(q.options) do
        table.insert(choice_lines, "- " .. opt.label)
        if opt.description then
          table.insert(choice_lines, "  " .. opt.description)
        end
      end
      table.insert(choice_lines, "")
    end

    local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local insert_pos = #current_lines
    vim.api.nvim_buf_set_lines(buf, insert_pos, insert_pos, false, choice_lines)
  end

  if win and vim.api.nvim_win_is_valid(win) then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
    if ok then
      local current_line = cursor[1]
      local old_line_count = #lines

      if current_line >= old_line_count then
        local total = vim.api.nvim_buf_line_count(buf)
        if total > 0 then
          pcall(vim.api.nvim_win_set_cursor, win, { total, 0 })
        end
      end
    end
  end
end

return M
