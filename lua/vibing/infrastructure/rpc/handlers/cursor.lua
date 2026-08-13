local M = {}

-- Get the current window cursor position as a table with fields `line` and `col`.
-- @return table with fields:
--   - `line`: 1-based line number.
--   - `col`: 0-based column index.
function M.get_cursor_position(params)
  local pos = vim.api.nvim_win_get_cursor(0)
  return {
    line = pos[1],
    col = pos[2],
  }
end

-- Set a window's cursor to the specified position.
--
-- `winnr` matters more than it looks. Window 0 is the *current* window, which is not the one
-- `win_open_file` just opened a file in — that handler restores focus before returning. So the
-- documented open-then-jump sequence ("show me the code", every stop of the code-tour skill)
-- moved the chat's cursor instead of the opened file's until this took a window.
--
-- @param params Table with cursor position fields:
--   - line (number): 1-based line number to move the cursor to (required).
--   - col (number): 0-based column number within the line (optional, defaults to 0).
--   - winnr (number): window to move (optional, defaults to the current window).
-- @return table A table `{ success = true }` on successful cursor move.
-- @throws error if `params.line` is not provided, or `params.winnr` is not a valid window.
function M.set_cursor_position(params)
  local line = params and params.line
  local col = params and params.col or 0
  local winnr = params and params.winnr
  if not line then
    error("Missing line parameter")
  end
  if winnr and not vim.api.nvim_win_is_valid(winnr) then
    error("Invalid window number: " .. tostring(winnr))
  end
  vim.api.nvim_win_set_cursor(winnr or 0, { line, col })
  return { success = true }
end

-- Retrieves the current visual selection's lines and positions.
-- @return table containing:
--   lines: array of strings for each selected line
--   start: position list for the selection start (as returned by `vim.fn.getpos`)
--   ["end"]: position list for the selection end (as returned by `vim.fn.getpos`)
function M.get_visual_selection(params)
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.fn.getline(start_pos[2], end_pos[2])
  return {
    lines = lines,
    start = start_pos,
    ["end"] = end_pos,
  }
end

return M
