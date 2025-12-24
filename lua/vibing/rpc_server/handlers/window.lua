local M = {}

function M.list_windows(params)
  local wins = {}
  local current_win = vim.api.nvim_get_current_win()
  for _, info in ipairs(vim.fn.getwininfo()) do
    local winnr = info.winid
    local bufnr = info.bufnr
    local config = vim.api.nvim_win_get_config(winnr)
    table.insert(wins, {
      winnr = winnr,
      bufnr = bufnr,
      buffer_name = vim.api.nvim_buf_get_name(bufnr),
      filetype = vim.bo[bufnr].filetype,
      width = info.width,
      height = info.height,
      row = config.row or 0,
      col = config.col or 0,
      relative = config.relative or "",
      is_current = winnr == current_win,
      is_floating = config.relative ~= "",
    })
  end
  return wins
end

function M.get_window_info(params)
  local winnr = params and params.winnr or 0
  if winnr ~= 0 and not vim.api.nvim_win_is_valid(winnr) then
    error("Invalid window number: " .. tostring(winnr))
  end
  local bufnr = vim.api.nvim_win_get_buf(winnr)
  local config = vim.api.nvim_win_get_config(winnr)
  local cursor = vim.api.nvim_win_get_cursor(winnr)
  return {
    winnr = winnr,
    bufnr = bufnr,
    buffer_name = vim.api.nvim_buf_get_name(bufnr),
    filetype = vim.bo[bufnr].filetype,
    width = vim.api.nvim_win_get_width(winnr),
    height = vim.api.nvim_win_get_height(winnr),
    row = config.row or 0,
    col = config.col or 0,
    relative = config.relative or "",
    is_current = winnr == vim.api.nvim_get_current_win(),
    is_floating = config.relative ~= "",
    cursor = { line = cursor[1], col = cursor[2] },
  }
end

function M.get_window_view(params)
  local winnr = params and params.winnr or 0
  if winnr ~= 0 and not vim.api.nvim_win_is_valid(winnr) then
    error("Invalid window number: " .. tostring(winnr))
  end
  local bufnr = vim.api.nvim_win_get_buf(winnr)
  local cursor = vim.api.nvim_win_get_cursor(winnr)
  local wininfo = vim.fn.getwininfo(winnr)[1]
  return {
    winnr = winnr,
    bufnr = bufnr,
    topline = vim.fn.line("w0", winnr),
    botline = vim.fn.line("w$", winnr),
    width = vim.api.nvim_win_get_width(winnr),
    height = vim.api.nvim_win_get_height(winnr),
    cursor = { line = cursor[1], col = cursor[2] },
    leftcol = wininfo and wininfo.leftcol or 0,
  }
end

function M.list_tabpages(params)
  local tabs = {}
  local current_tab = vim.api.nvim_get_current_tabpage()
  for _, tabnr in ipairs(vim.api.nvim_list_tabpages()) do
    local wins = vim.api.nvim_tabpage_list_wins(tabnr)
    local win_info = {}
    for _, winnr in ipairs(wins) do
      local bufnr = vim.api.nvim_win_get_buf(winnr)
      table.insert(win_info, {
        winnr = winnr,
        bufnr = bufnr,
        buffer_name = vim.api.nvim_buf_get_name(bufnr),
      })
    end
    table.insert(tabs, {
      tabnr = tabnr,
      window_count = #wins,
      windows = win_info,
      is_current = tabnr == current_tab,
    })
  end
  return tabs
end

function M.set_window_width(params)
  local winnr = params and params.winnr or 0
  local width = params and params.width
  if not width then
    error("Missing width parameter")
  end
  if winnr ~= 0 and not vim.api.nvim_win_is_valid(winnr) then
    error("Invalid window number: " .. tostring(winnr))
  end
  vim.api.nvim_win_set_width(winnr, width)
  return { success = true }
end

function M.set_window_height(params)
  local winnr = params and params.winnr or 0
  local height = params and params.height
  if not height then
    error("Missing height parameter")
  end
  if winnr ~= 0 and not vim.api.nvim_win_is_valid(winnr) then
    error("Invalid window number: " .. tostring(winnr))
  end
  vim.api.nvim_win_set_height(winnr, height)
  return { success = true }
end

function M.focus_window(params)
  local winnr = params and params.winnr
  if not winnr then
    error("Missing winnr parameter")
  end
  if not vim.api.nvim_win_is_valid(winnr) then
    error("Invalid window number: " .. tostring(winnr))
  end
  vim.api.nvim_set_current_win(winnr)
  return { success = true }
end

function M.win_set_buf(params)
  local winnr = params and params.winnr
  local bufnr = params and params.bufnr
  if not winnr or not bufnr then
    error("Missing winnr or bufnr parameter")
  end
  if not vim.api.nvim_win_is_valid(winnr) then
    error("Invalid window number: " .. tostring(winnr))
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("Invalid buffer number: " .. tostring(bufnr))
  end
  vim.api.nvim_win_set_buf(winnr, bufnr)
  return { success = true }
end

function M.win_open_file(params)
  local winnr = params and params.winnr
  local filepath = params and params.filepath
  if not winnr or not filepath then
    error("Missing winnr or filepath parameter")
  end
  -- Validate filepath
  if filepath == "" or filepath:match("^%s*$") then
    error("Invalid filepath: empty or whitespace-only")
  end
  if filepath:match("\0") then
    error("Invalid filepath: contains null character")
  end
  if not vim.api.nvim_win_is_valid(winnr) then
    error("Invalid window number: " .. tostring(winnr))
  end
  local current = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(winnr)
  vim.cmd("edit " .. vim.fn.fnameescape(filepath))
  local opened_bufnr = vim.api.nvim_get_current_buf()
  if winnr ~= current then
    vim.api.nvim_set_current_win(current)
  end
  return {
    success = true,
    bufnr = opened_bufnr
  }
end

return M
