--- set_cursor_position defaulted to window 0 with no way to name another one, so the documented
--- "open the file, then jump to the line" sequence moved the *chat's* cursor: win_open_file
--- restores focus before it returns.
local cursor = require("vibing.infrastructure.rpc.handlers.cursor")

describe("set_cursor_position", function()
  local origin_win
  local other_win
  local origin_buf
  local other_buf

  local function fill(buf)
    local lines = {}
    for i = 1, 20 do
      lines[i] = "line " .. i
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end

  before_each(function()
    origin_buf = vim.api.nvim_create_buf(false, true)
    fill(origin_buf)
    vim.api.nvim_set_current_buf(origin_buf)
    origin_win = vim.api.nvim_get_current_win()

    vim.cmd("vsplit")
    other_win = vim.api.nvim_get_current_win()
    other_buf = vim.api.nvim_create_buf(false, true)
    fill(other_buf)
    vim.api.nvim_win_set_buf(other_win, other_buf)

    vim.api.nvim_set_current_win(origin_win)
    vim.api.nvim_win_set_cursor(origin_win, { 1, 0 })
    vim.api.nvim_win_set_cursor(other_win, { 1, 0 })
  end)

  after_each(function()
    if other_win and vim.api.nvim_win_is_valid(other_win) and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(other_win, true)
    end
    for _, buf in ipairs({ origin_buf, other_buf }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  it("moves the named window, not the active one", function()
    cursor.set_cursor_position({ line = 12, col = 2, winnr = other_win })

    assert.equals(12, vim.api.nvim_win_get_cursor(other_win)[1])
    assert.equals(2, vim.api.nvim_win_get_cursor(other_win)[2])
    assert.equals(1, vim.api.nvim_win_get_cursor(origin_win)[1], "the active window must not move")
    assert.equals(origin_win, vim.api.nvim_get_current_win(), "focus must stay put")
  end)

  it("still moves the active window when winnr is omitted", function()
    -- Every existing caller passes no winnr; that has to keep working.
    cursor.set_cursor_position({ line = 7 })

    assert.equals(7, vim.api.nvim_win_get_cursor(origin_win)[1])
    assert.equals(1, vim.api.nvim_win_get_cursor(other_win)[1])
  end)

  it("defaults col to 0", function()
    cursor.set_cursor_position({ line = 5, winnr = other_win })
    assert.equals(0, vim.api.nvim_win_get_cursor(other_win)[2])
  end)

  it("rejects an invalid window instead of silently moving the active one", function()
    local ok, err = pcall(cursor.set_cursor_position, { line = 3, winnr = 999999 })

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("Invalid window number", 1, true))
    assert.equals(1, vim.api.nvim_win_get_cursor(origin_win)[1])
  end)

  it("still requires a line", function()
    assert.is_false(pcall(cursor.set_cursor_position, { winnr = other_win }))
    assert.is_false(pcall(cursor.set_cursor_position, {}))
  end)
end)
