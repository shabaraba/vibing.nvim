local M = {}

function M.buf_get_lines(params)
  local bufnr = params and params.bufnr or 0
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

function M.buf_set_lines(params)
  local bufnr = params and params.bufnr or 0
  local lines = params and params.lines
  if type(lines) == "string" then
    lines = vim.split(lines, "\n")
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return { success = true }
end

function M.get_current_file(params)
  local bufnr = vim.api.nvim_get_current_buf()
  return {
    bufnr = bufnr,
    filename = vim.fn.expand("%:p"),
    filetype = vim.bo.filetype,
    modified = vim.bo[bufnr].modified,
  }
end

function M.list_buffers(params)
  local bufs = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      table.insert(bufs, {
        bufnr = bufnr,
        name = vim.api.nvim_buf_get_name(bufnr),
        modified = vim.bo[bufnr].modified,
        filetype = vim.bo[bufnr].filetype,
      })
    end
  end
  return bufs
end

return M
