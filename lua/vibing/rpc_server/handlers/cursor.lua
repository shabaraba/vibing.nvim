local M = {}

function M.get_cursor_position(params)
  local pos = vim.api.nvim_win_get_cursor(0)
  return {
    line = pos[1],
    col = pos[2],
  }
end

function M.set_cursor_position(params)
  local line = params and params.line
  local col = params and params.col or 0
  if not line then
    error("Missing line parameter")
  end
  vim.api.nvim_win_set_cursor(0, { line, col })
  return { success = true }
end

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
