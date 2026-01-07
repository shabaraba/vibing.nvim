local Timestamp = require("vibing.core.utils.timestamp")
local Context = require("vibing.application.context.manager")

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

  local contextText = "Context: " .. Context.format_for_display()
  local contextLines = vim.split(contextText, "\n", { plain = true })
  vim.list_extend(lines, contextLines)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  return #lines - 2
end

---Contextディスプレイを更新
---@param buf number バッファ番号
function M.updateContextLine(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local contextText = "Context: " .. Context.format_for_display()
  local contextLines = vim.split(contextText, "\n", { plain = true })

  local contextLinePos = nil
  for i = #lines, 1, -1 do
    if lines[i]:match("^Context:") then
      contextLinePos = i
      break
    end
  end

  vim.schedule(function()
    if contextLinePos then
      vim.api.nvim_buf_set_lines(buf, contextLinePos - 1, contextLinePos, false, contextLines)
    else
      local newLines = { "" }
      vim.list_extend(newLines, contextLines)
      vim.api.nvim_buf_set_lines(buf, #lines, #lines, false, newLines)
    end
  end)
end

-- Backward compatibility alias
M.update_context_line = M.updateContextLine

---カーソルを末尾に移動
---@param win number ウィンドウ番号
---@param buf number バッファ番号
function M.moveCursorToEnd(win, buf)
  if type(win) ~= "number" or type(buf) ~= "number" then
    return
  end
  if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lineCount = vim.api.nvim_buf_line_count(buf)
  if lineCount > 0 then
    pcall(vim.api.nvim_win_set_cursor, win, { lineCount, 0 })
  end
end

-- Backward compatibility alias
M.move_cursor_to_end = M.moveCursorToEnd

---新しいユーザーセクションを追加
---@param buf number バッファ番号
---@param win number? ウィンドウ番号
---@param pendingChoices table? 保留中の選択肢
function M.addUserSection(buf, win, pendingChoices)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines, #lines)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local newLines = {
    "",
    Timestamp.create_unsent_user_header(),
    "",
    "",
  }
  vim.api.nvim_buf_set_lines(buf, #lines, #lines, false, newLines)

  if pendingChoices then
    local choiceLines = {}
    for _, q in ipairs(pendingChoices) do
      for _, opt in ipairs(q.options) do
        table.insert(choiceLines, "- " .. opt.label)
        if opt.description then
          table.insert(choiceLines, "  " .. opt.description)
        end
      end
      table.insert(choiceLines, "")
    end

    local currentLines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local insertPos = #currentLines
    vim.api.nvim_buf_set_lines(buf, insertPos, insertPos, false, choiceLines)
  end

  if win and vim.api.nvim_win_is_valid(win) then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
    if ok then
      local currentLine = cursor[1]
      local oldLineCount = #lines

      if currentLine >= oldLineCount then
        local total = vim.api.nvim_buf_line_count(buf)
        if total > 0 then
          pcall(vim.api.nvim_win_set_cursor, win, { total, 0 })
        end
      end
    end
  end
end

-- Backward compatibility alias
M.add_user_section = M.addUserSection

return M
