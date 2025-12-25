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

-- Set the window cursor to the specified position.
-- @param params Table with cursor position fields:
--   - line (number): 1-based line number to move the cursor to (required).
--   - col (number): 0-based column number within the line (optional, defaults to 0).
-- @return table A table `{ success = true }` on successful cursor move.
-- @throws error if `params.line` is not provided.
function M.set_cursor_position(params)
  local line = params and params.line
  local col = params and params.col or 0
  if not line then
    error("Missing line parameter")
  end
  vim.api.nvim_win_set_cursor(0, { line, col })
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
