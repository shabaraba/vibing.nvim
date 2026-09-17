local MarkdownFence = require("vibing.core.utils.markdown_fence")
local Timestamp = require("vibing.core.utils.timestamp")
local Context = require("vibing.application.context.manager")
local Modes = require("vibing.core.constants.modes")

local M = {}

---nvim_buf_set_lines は改行を含む要素を拒否するため、行配列を1行1要素に平坦化する
---@param entries string[]
---@return string[]
local function flatten_lines(entries)
  local result = {}
  for _, entry in ipairs(entries) do
    if entry:find("[\r\n]") then
      for _, line in ipairs(vim.split(entry, "\r?\n", { trimempty = false })) do
        table.insert(result, (line:gsub("\r", "")))
      end
    else
      table.insert(result, entry)
    end
  end
  return result
end

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

  -- working_dir
  if frontmatter.working_dir then
    table.insert(lines, "working_dir: " .. frontmatter.working_dir)
  end

  -- agent
  local agent = frontmatter.agent or (config.adapter or "claude")
  table.insert(lines, "agent: " .. agent)

  -- model
  local model = frontmatter.model or (config.agent and config.agent.default_model)
  if model then
    table.insert(lines, "model: " .. model)
  end

  -- Always show the effective choice. `default` deliberately produces no CLI override, which is
  -- the exact behaviour chats had before effort became configurable.
  local effort = frontmatter.effort or (config.agent and config.agent.default_effort) or Modes.DEFAULT_EFFORT
  table.insert(lines, "effort: " .. effort)

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
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end

  local lineCount = vim.api.nvim_buf_line_count(buf)
  if lineCount > 0 then
    pcall(vim.api.nvim_win_set_cursor, win, { lineCount, 0 })
  end
end

-- Backward compatibility alias
M.move_cursor_to_end = M.moveCursorToEnd

---Add new user section
---@param buf number Buffer number
---@param win number? Window number
---@param pendingChoices table? Pending choices
---@param pendingApprovals table[]? Tool approval requests still waiting, in display order. A list
---  rather than one, because a CLI runs several PreToolUse hooks at once — measured on claude as
---  three hooks starting 0.54s apart and overlapping for their whole duration. Each entry carries
---  its `request_id`, which is what makes an answer attributable when the numbered lists repeat.
---@param initial_message string? Initial message content (for programmatic send)
---@param header string? Section header to use instead of the plain unsent `## User` one.
---  Delivered chat-to-chat messages pass their own (`## Request` / `## Report` / `## Notice`);
---  it must still be an unsent header, since `commit_user_message` is what stamps it at send
function M.addUserSection(buf, win, pendingChoices, pendingApprovals, initial_message, header)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines, #lines)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local newLines = {
    "",
    header or Timestamp.create_unsent_user_header(),
    "",
  }

  -- Insert message content if provided (for programmatic send)
  if initial_message and initial_message ~= "" then
    -- 配達された本文もそのままバッファの markdown になるので、閉じフェンスを割っておく
    local message_lines = MarkdownFence.normalize(vim.split(initial_message, "\n", { plain = true }))
    for _, line in ipairs(message_lines) do
      table.insert(newLines, line)
    end
  end

  table.insert(newLines, "")
  vim.api.nvim_buf_set_lines(buf, #lines, #lines, false, flatten_lines(newLines))

  if pendingChoices then
    local choiceLines = {}
    for _, q in ipairs(pendingChoices) do
      -- Add question text if available
      if q.question and q.question ~= "" then
        table.insert(choiceLines, q.question)
        table.insert(choiceLines, "")
      end

      -- Use numbered list for single-select, bullet list for multi-select
      -- Default to single-select (numbered list) when multiSelect is not explicitly true
      local useNumberedList = q.multiSelect ~= true
      local optionIndex = 1
      for _, opt in ipairs(q.options or {}) do
        -- Safe label extraction
        local label = (opt.label and opt.label ~= "") and opt.label or ""
        if label ~= "" then
          if useNumberedList then
            table.insert(choiceLines, optionIndex .. ". " .. label)
            optionIndex = optionIndex + 1
          else
            table.insert(choiceLines, "- " .. label)
          end
          if opt.description and opt.description ~= "" then
            table.insert(choiceLines, "  " .. tostring(opt.description))
          end
        end
      end
      table.insert(choiceLines, "")
    end

    local currentLines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local insertPos = #currentLines
    vim.api.nvim_buf_set_lines(buf, insertPos, insertPos, false, flatten_lines(choiceLines))
  end

  if pendingApprovals and #pendingApprovals > 0 then
    local approvalLines = {}
    local ApprovalParser = require("vibing.presentation.chat.modules.approval_parser")

    for _, pendingApproval in ipairs(pendingApprovals) do
      -- Warning header
      table.insert(approvalLines, "⚠️  Tool approval required")
      if pendingApproval.expired then
        -- Marked in place rather than deleted. The user may be editing this buffer right now, and
        -- removing lines under their cursor moves everything below it.
        --
        -- **The options stay too.** Expiry denied the one call that was in flight; it did not
        -- withdraw the user's chance to grant the permission — somebody back from a long absence
        -- answers this exactly as before, and the answer travels as a retry instead of reaching a
        -- hook that is no longer there.
        table.insert(approvalLines, "   (expired — that call was denied; answering now retries it)")
      end
      table.insert(approvalLines, "")

      -- Tool information
      local toolName = (pendingApproval.tool and pendingApproval.tool ~= "") and pendingApproval.tool or "[unknown]"
      table.insert(approvalLines, "Tool: " .. toolName)

      -- Show input details based on tool type (nil-safe)
      if pendingApproval.input then
        if pendingApproval.input.command then
          table.insert(approvalLines, "Command: " .. tostring(pendingApproval.input.command))
        end
        if pendingApproval.input.file_path then
          table.insert(approvalLines, "File: " .. tostring(pendingApproval.input.file_path))
        end
        if pendingApproval.input.pattern then
          table.insert(approvalLines, "Pattern: " .. tostring(pendingApproval.input.pattern))
        end
        if pendingApproval.input.url then
          table.insert(approvalLines, "URL: " .. tostring(pendingApproval.input.url))
        end
      end

      table.insert(approvalLines, "")

      -- One numbered list per prompt, so the numbers repeat across prompts — which is exactly why
      -- the line carries its request id. `approval_parser.option_line` is the only place that
      -- composes it, shared with `approval_delegate` so a delegated answer is byte-identical to
      -- the line a human would have left behind.
      do
        local optionIndex = 1
        for _, opt in ipairs(pendingApproval.options or {}) do
          local label = (opt.label and opt.label ~= "") and opt.label or ""
          if label ~= "" then
            table.insert(
              approvalLines,
              ApprovalParser.option_line(optionIndex, label, pendingApproval.request_id)
            )
            optionIndex = optionIndex + 1
          end
        end

        -- 止まっていることが読めるようにする。承認プロンプトの下で何も動かない状態は、
        -- ユーザーからは「固まった」と区別がつかない — 待たせる設計ではそれが最大
        -- `permissions.approval_wait_sec` 続く。kill する経路には止めている出力が無いので
        -- 書かない（`waiting` がそれを言う）。期限切れならもう何も止めていないので、これも書かない
        if pendingApproval.waiting and not pendingApproval.expired then
          table.insert(approvalLines, "   (the rest of this turn's output is paused until this is answered)")
          table.insert(approvalLines, "")
        end
      end
    end

    table.insert(approvalLines, "Delete every option line except the one you want, then press <CR>.")
    table.insert(approvalLines, "")

    local currentLines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local insertPos = #currentLines
    vim.api.nvim_buf_set_lines(buf, insertPos, insertPos, false, flatten_lines(approvalLines))
  end

  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
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
