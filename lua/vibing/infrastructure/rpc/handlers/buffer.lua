local M = {}

local BufferIdentifier = require("vibing.core.utils.buffer_identifier")

-- Read only the buffer's last `## ...` section, by growing a backward-read chunk until a header
-- turns up (or the chunk covers the whole buffer) — the `last_section` counterpart to the
-- tail_lines-only fast path below. Doubling from a few hundred lines means an ordinary single
-- turn (the overwhelmingly common case) is found in one or two reads instead of the full 400k
-- lines a chat can run to (#694 follow-up flagged by review on PR #707).
-- @param bufnr number
-- @param tail_lines integer? Already normalized by `BufferWindow.normalize_tail_lines`.
-- @return string[] windowed
-- @return integer total_lines
local function read_last_section(bufnr, tail_lines)
  local BufferWindow = require("vibing.domain.chat.buffer_window")
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local chunk_size = 500
  local chunk, from

  repeat
    from = math.max(0, total_lines - chunk_size)
    chunk = vim.api.nvim_buf_get_lines(bufnr, from, total_lines, false)
    chunk_size = chunk_size * 2
  until BufferWindow.find_last_header(chunk) or from == 0

  local windowed = BufferWindow.slice(chunk, { tail_lines = tail_lines, last_section = true })
  return windowed, total_lines
end

-- Retrieve all lines from the specified buffer.
-- @param params? Table with optional fields.
-- @param params.bufnr? number Buffer number to read from; defaults to 0 (current buffer).
-- @param params.file_path? string Chat file to read instead, opened in the background if it is
--   not already (see `application/chat/chat_locator.lua`). Mutually exclusive with `bufnr`, and
--   chat files only — an ordinary file has `nvim_load_buffer`, and this path opens and attaches
--   a chat buffer, which is not what reading a source file should do.
-- @param params.include_chat_status? boolean Wrap the result and attach the buffer's chat status
--   and its real total line count. Independent of `tail_lines`/`last_section` below — those
--   window the lines either shape returns, so a caller that wants only a tail read and not the
--   chat-status wrapper still gets one.
-- @param params.tail_lines? number Keep only the last N lines of the (possibly `last_section`-cut)
--   result.
-- @param params.last_section? boolean Keep only the buffer's last `## ...` section (header
--   boundaries from `core/utils/timestamp.lua`).
-- @return string[]|table Bare line array by default; `{ lines, total_lines, bufnr, chat_status }`
--   when `include_chat_status` is set (`chat_status` is "responding"/"idle"/"waiting_approval"/
--   "asked_question"/"error", or absent for a buffer that is not a vibing.nvim chat). An MCP
--   server older than a value names it rather than dropping it, so a status added later reads as
--   "go look" instead of as silence. The shape stays opt-in because the MCP server and this
--   plugin are installed separately and can be at different versions: an older MCP server sends
--   no flag and must keep receiving the array it calls `.join()` on. `total_lines` cannot be
--   reported in that bare shape, which is exactly why it lives inside the wrapped one instead of
--   next to the windowed lines themselves.
--
--   `bufnr` is what makes the *other* direction of that skew safe. A `file_path` reaching a
--   Neovim too old to know the argument would be ignored, and the caller would be handed the
--   current buffer's text as though it were the chat it named — silently, and reported `idle`.
--   Answering with the buffer actually read lets the server tell that case apart. The send path
--   needs no equivalent: it errors outright when it can find no target.
function M.buf_get_lines(params)
  local bufnr = require("vibing.infrastructure.rpc.handlers.bufnr").resolve_chat_target(params) or 0
  local BufferWindow = require("vibing.domain.chat.buffer_window")
  -- Normalized once, through the same primitive `BufferWindow.slice` uses below, so a negative or
  -- fractional value cannot be read one way on this fast path and a different way on that one.
  local tail_lines = BufferWindow.normalize_tail_lines(params and params.tail_lines)
  local last_section = params and params.last_section

  local windowed, total_lines
  if last_section then
    windowed, total_lines = read_last_section(bufnr, tail_lines)
  elseif tail_lines then
    -- Read only the requested tail instead of the whole buffer: the entire point of asking for
    -- the last 40 lines of a 400k-line chat is to not pay for reading the other 399,960 (#694).
    total_lines = vim.api.nvim_buf_line_count(bufnr)
    local from = tail_lines < total_lines and (total_lines - tail_lines) or 0
    windowed = vim.api.nvim_buf_get_lines(bufnr, from, total_lines, false)
  else
    windowed = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    total_lines = #windowed
  end

  if not (params and params.include_chat_status) then
    return windowed
  end

  local ChatStatus = require("vibing.presentation.chat.modules.chat_status")
  return {
    lines = windowed,
    total_lines = total_lines,
    bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr,
    chat_status = ChatStatus.get(bufnr),
  }
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
--   rpc_port (number|nil): RPC port of this Neovim instance, or nil if server not running.
function M.get_current_file(params)
  local bufnr = vim.api.nvim_get_current_buf()
  local rpc_server = require("vibing.infrastructure.rpc.server")
  return {
    bufnr = bufnr,
    filename = vim.fn.expand("%:p"),
    filetype = vim.bo.filetype,
    modified = vim.bo[bufnr].modified,
    rpc_port = rpc_server.get_port(),
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
