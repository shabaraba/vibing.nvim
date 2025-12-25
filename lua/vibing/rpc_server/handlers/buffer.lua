local M = {}

local BufferIdentifier = require("vibing.utils.buffer_identifier")

-- Retrieve all lines from the specified buffer.
-- @param params? Table with optional fields.
-- @param params.bufnr? number Buffer number to read from; defaults to 0 (current buffer).
-- @return string[] A list of lines from the buffer, in buffer order (each element is a line without trailing newlines).
function M.buf_get_lines(params)
  local bufnr = params and params.bufnr or 0
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- Replace the entire contents of a buffer with the provided lines.
-- @param params Table of options:
--   bufnr (number, optional): buffer number to modify; defaults to 0 (current buffer).
--   lines (string|table): new buffer contents; a string will be split on newline into lines.
-- @return table `{ success = true, filename = string }` when the buffer was updated. filename is the buffer's file path (or "[Buffer N]" for unnamed buffers).
function M.buf_set_lines(params)
  local bufnr = params and params.bufnr or 0
  local lines = params and params.lines
  if type(lines) == "string" then
    lines = vim.split(lines, "\n")
  end

  -- Convert bufnr 0 to actual buffer number
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  -- Get the buffer's file path
  local filename = vim.api.nvim_buf_get_name(bufnr)

  -- For unnamed buffers, use [Buffer N] identifier
  if filename == "" then
    filename = BufferIdentifier.create_identifier(bufnr)
  end

  return {
    success = true,
    filename = filename,
    bufnr = bufnr,
  }
end

-- Get metadata for the current buffer and its file.
-- @return table A table with fields:
--   bufnr (number): current buffer number.
--   filename (string): absolute path of the current file.
--   filetype (string): filetype of the current buffer.
--   modified (boolean): whether the current buffer has unsaved changes.
function M.get_current_file(params)
  local bufnr = vim.api.nvim_get_current_buf()
  return {
    bufnr = bufnr,
    filename = vim.fn.expand("%:p"),
    filetype = vim.bo.filetype,
    modified = vim.bo[bufnr].modified,
  }
end

-- List loaded buffers with basic metadata.
-- Each list element is a table describing a loaded buffer.
-- @return A list where each element is a table with fields:
--   `bufnr` (number) — buffer number,
--   `name` (string) — buffer name (path),
--   `modified` (boolean) — `true` if the buffer is modified, `false` otherwise,
--   `filetype` (string) — buffer filetype.
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

-- Load a file into a Neovim buffer, reusing an existing buffer when available.
-- @param params Table with a `filepath` string field specifying the file path to load.
-- @return table { bufnr = number, already_loaded = boolean } where `bufnr` is the buffer number and `already_loaded` is true if the buffer already existed.
-- @throws If `params.filepath` is missing: error("Missing filepath parameter").
-- @throws If the buffer fails to load: error("Failed to load buffer: " .. fullpath).
function M.load_buffer(params)
  local filepath = params and params.filepath
  if not filepath then
    error("Missing filepath parameter")
  end

  -- Expand path to absolute
  local fullpath = vim.fn.fnamemodify(filepath, ":p")

  -- Check if buffer already exists
  local existing_bufnr = vim.fn.bufnr(fullpath)
  if existing_bufnr ~= -1 then
    -- Buffer exists, make sure it's loaded
    if not vim.api.nvim_buf_is_loaded(existing_bufnr) then
      vim.fn.bufload(existing_bufnr)
    end
    return { bufnr = existing_bufnr, already_loaded = true }
  end

  -- Load file into new buffer (background, no display)
  vim.cmd("badd " .. vim.fn.fnameescape(fullpath))
  local bufnr = vim.fn.bufnr(fullpath)

  if bufnr == -1 then
    error("Failed to load buffer: " .. fullpath)
  end

  -- Actually load the buffer content to trigger LSP attachment
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end

  return { bufnr = bufnr, already_loaded = false }
end

return M
