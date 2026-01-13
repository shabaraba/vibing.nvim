local Timestamp = require("vibing.core.utils.timestamp")
local Context = require("vibing.application.context.manager")

local M = {}

---バッファを初期化（フロントマター + 初期コンテンツ）
---@param buf number バッファ番号
---@param session? Vibing.ChatSession セッション（指定時はそのfrontmatterを使用）
---@return number cursor_line カーソル行番号
function M.init_content(buf, session)
  local vibing = require("vibing")
  local config = vibing.get_config()

  local frontmatter = session and session.frontmatter or {}

  local lines = {
    "---",
    "vibing.nvim: true",
    "session_id: " .. (frontmatter.session_id or "~"),
    "created_at: " .. (frontmatter.created_at or os.date("%Y-%m-%dT%H:%M:%S")),
  }

  -- mode
  local mode = frontmatter.mode or (config.agent and config.agent.default_mode)
  if mode then
    table.insert(lines, "mode: " .. mode)
  end

  -- model
  local model = frontmatter.model or (config.agent and config.agent.default_model)
  if model then
    table.insert(lines, "model: " .. model)
  end

  -- permission_mode
  local permission_mode = frontmatter.permission_mode or (config.permissions and config.permissions.mode)
  if permission_mode then
    table.insert(lines, "permission_mode: " .. permission_mode)
  end

  -- permissions_allow
  local allow = frontmatter.permissions_allow or (config.permissions and config.permissions.allow) or {}
  if #allow > 0 then
    table.insert(lines, "permissions_allow:")
    for _, tool in ipairs(allow) do
      table.insert(lines, "  - " .. tool)
    end
  end

  -- permissions_deny
  local deny = frontmatter.permissions_deny or (config.permissions and config.permissions.deny) or {}
  if #deny > 0 then
    table.insert(lines, "permissions_deny:")
    for _, tool in ipairs(deny) do
      table.insert(lines, "  - " .. tool)
    end
  end

  -- permissions_ask
  local ask = frontmatter.permissions_ask or (config.permissions and config.permissions.ask) or {}
  if #ask > 0 then
    table.insert(lines, "permissions_ask:")
    for _, tool in ipairs(ask) do
      table.insert(lines, "  - " .. tool)
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

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- カーソル位置は最後の行（空行の位置）
  return #lines
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
      -- Use numbered list for single-select, bullet list for multi-select
      -- Default to single-select (numbered list) when multiSelect is not explicitly true
      local useNumberedList = q.multiSelect ~= true
      local optionIndex = 1
      for _, opt in ipairs(q.options) do
        if useNumberedList then
          table.insert(choiceLines, optionIndex .. ". " .. opt.label)
          optionIndex = optionIndex + 1
        else
          table.insert(choiceLines, "- " .. opt.label)
        end
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
