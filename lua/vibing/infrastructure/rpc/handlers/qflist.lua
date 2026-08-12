local M = {}

-- Reject a non-positive-integer stop field. `index` is the stop's 1-based position and is named
-- in the error so the caller knows which of its stops to fix.
-- @throws If `value` is not a positive integer.
local function assert_positive_integer(value, index, field)
  if type(value) ~= "number" or value < 1 or value ~= math.floor(value) then
    error(string.format("items[%d].%s must be a positive integer", index, field))
  end
end

-- Validate one tour stop and normalize it into a quickfix item.
-- @param item Table: raw stop from the MCP payload.
-- @param index Number: 1-based position of the stop.
-- @return Table quickfix item.
-- @throws If a required field is missing/mistyped, or the file does not exist.
local function to_qf_item(item, index)
  if type(item) ~= "table" then
    error(string.format("items[%d] must be an object", index))
  end

  local filename = item.filename
  if type(filename) ~= "string" or filename == "" then
    error(string.format("items[%d].filename is required and must be a non-empty string", index))
  end

  -- An `lnum` past the end of the file is deliberately not rejected: catching it would mean
  -- reading every referenced file just to count lines, and Vim clamps the cursor on jump anyway.
  assert_positive_integer(item.lnum, index, "lnum")
  if item.col ~= nil then
    assert_positive_integer(item.col, index, "col")
  end

  -- Existence is checked here rather than in the MCP server because a relative path resolves
  -- against this instance's cwd, which for a worktree chat is not the server process's cwd.
  if vim.fn.filereadable(vim.fn.fnamemodify(filename, ":p")) == 0 then
    error(string.format("items[%d].filename does not exist: %s", index, filename))
  end

  -- The RPC port takes requests from anything that can reach it, not only the MCP handler that
  -- already ran this through Zod, so the label is type-checked here too rather than handed to
  -- setqflist as whatever arrived.
  if item.text ~= nil and type(item.text) ~= "string" then
    error(string.format("items[%d].text must be a string", index))
  end

  return {
    filename = filename,
    lnum = item.lnum,
    col = item.col,
    text = item.text or "",
  }
end

-- Push a route of file:line stops as a NEW quickfix list.
-- @param params Table with call parameters.
-- @param params.items Table: array of stops (required, non-empty). Each stop takes `filename`
--   (string, required, must exist), `lnum` (number, required, 1-based), `col` (number, optional,
--   1-based) and `text` (string, optional).
-- @param params.title String: quickfix list title (optional, defaults to "vibing.nvim").
-- @param params.open Boolean: also open the quickfix window (optional). Focus is restored to the
--   window that was current, matching win_open_file.
-- @return Table with fields:
--   success boolean: true on success.
--   count number: number of stops pushed.
--   title string: the title the list was given.
--   qf_winnr number|nil: quickfix window id, only when `open` was requested.
-- @throws If `items` is missing, not an array, empty, or contains an invalid stop.
function M.set_qflist(params)
  local items = params and params.items
  if type(items) ~= "table" or #items == 0 then
    error("items must be a non-empty array")
  end

  local qf_items = {}
  for index, item in ipairs(items) do
    table.insert(qf_items, to_qf_item(item, index))
  end

  local title = params.title
  if type(title) ~= "string" or title == "" then
    title = "vibing.nvim"
  end

  -- " " pushes a fresh list onto the quickfix stack instead of replacing the current one, so
  -- whatever the user had in quickfix before the tour is still reachable with :colder.
  vim.fn.setqflist({}, " ", { title = title, items = qf_items })

  local result = { success = true, count = #qf_items, title = title }

  if params.open then
    local original_win = vim.api.nvim_get_current_win()
    vim.cmd("copen")
    result.qf_winnr = vim.api.nvim_get_current_win()
    if original_win ~= result.qf_winnr and vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
  end

  return result
end

return M
