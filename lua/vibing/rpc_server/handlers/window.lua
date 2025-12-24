local M = {}

-- Returns a list of Neovim windows with identifying and layout metadata.
-- @return Array of tables, each containing:
--   `winnr` (number) – window id,
--   `bufnr` (number) – buffer id,
--   `buffer_name` (string) – buffer full name/path,
--   `filetype` (string) – buffer filetype,
--   `width` (number) – window width in columns,
--   `height` (number) – window height in rows,
--   `row` (number) – window row position (or 0),
--   `col` (number) – window column position (or 0),
--   `relative` (string) – relative positioning mode (empty string for no relative),
--   `is_current` (boolean) – `true` if the window is the current window, `false` otherwise,
--   `is_floating` (boolean) – `true` if the window is a floating window, `false` otherwise.
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

-- Retrieve detailed information about a specific window.
-- @param params Optional table. Fields:
--   - winnr: Window number to query (0 for current window).
-- @return Table with the window's metadata:
--   - winnr: The queried window number.
--   - bufnr: Buffer number displayed in the window.
--   - buffer_name: Full path of the buffer shown in the window.
--   - filetype: Buffer filetype.
--   - width: Window width in columns.
--   - height: Window height in rows.
--   - row: Window row position (or 0 if not set).
--   - col: Window column position (or 0 if not set).
--   - relative: Window's relative positioning mode (empty string for normal windows).
--   - is_current: `true` if the window is the current window, `false` otherwise.
--   - is_floating: `true` if the window is floating, `false` otherwise.
--   - cursor: Table with `line` (1-based) and `col` (0-based) for the window's cursor.
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

-- Retrieve a compact view snapshot for a window.
-- @param params Optional table. Supported key:
--   - winnr: window number to inspect (0 for the current window).
-- @return A table containing:
--   - winnr: the inspected window number.
--   - bufnr: buffer number displayed in the window.
--   - topline: first visible line number in the window.
--   - botline: last visible line number in the window.
--   - width: window width in columns.
--   - height: window height in rows.
--   - cursor: table with `line` and `col` for the window cursor.
--   - leftcol: leftmost displayed column (0 if unavailable).
-- @throws Error when `winnr` is non-zero and does not refer to a valid window.
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

-- List all tabpages with their windows and associated buffers.
-- @return An array of tables, one per tabpage. Each table contains:
--   * `tabnr` — the tabpage id.
--   * `window_count` — the number of windows in the tabpage.
--   * `windows` — an array of window entries; each entry has `winnr`, `bufnr`, and `buffer_name`.
--   * `is_current` — `true` if the tabpage is the active tabpage, `false` otherwise.
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

-- Set the width of the specified window.
-- @param params Table with optional fields:
--   - winnr (number): Window handle to modify; use 0 to target the current window. Defaults to 0.
--   - width (number): Desired width in columns. Required.
-- @return Table containing `success = true` when the width was applied.
-- @throws If `width` is missing.
-- @throws If `winnr` is not 0 and does not refer to a valid window.
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

-- Set the height of a Neovim window.
-- @param params Table with optional fields:
--   - winnr: Window handle (0 for current window). Defaults to 0.
--   - height: Required integer height in rows to apply to the window.
-- @return Table `{ success = true }` on success.
-- @throws If `height` is missing.
-- @throws If `winnr` is non-zero and not a valid window.
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

-- Focuses the Neovim window specified by `winnr`.
-- @param params Table of parameters.
-- @param params.winnr number The window number (as accepted by Neovim) to make current.
-- @return table A table `{ success = true }` on success.
-- @throws error If `winnr` is missing.
-- @throws error If `winnr` does not refer to a valid window.
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

-- Set the buffer displayed in a specific window.
-- @param params Table containing call parameters.
--   - winnr: The target window number.
--   - bufnr: The buffer number to show in the window.
-- @return Table with field `success` set to `true` on success.
-- @throws If `winnr` or `bufnr` is missing.
-- @throws If `winnr` is not a valid window.
-- @throws If `bufnr` is not a valid buffer.
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

-- Open the given file in the specified window and return the buffer number of the opened file.
-- @param params Table with call parameters.
-- @param params.winnr Number: target window id to open the file in (required).
-- @param params.filepath String: path to the file to open (required; must not be empty, whitespace-only, or contain NUL).
-- @return Table with fields:
--   success boolean: true on success.
--   bufnr number: buffer number of the opened file.
-- @throws If `winnr` or `filepath` is missing, if `filepath` is empty/whitespace-only or contains a NUL, or if `winnr` is not a valid window.
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
