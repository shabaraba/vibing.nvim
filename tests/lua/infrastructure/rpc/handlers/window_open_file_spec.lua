--- win_open_file is what the "show me the code" instruction and the vibing-code-tour skill both
--- run on, and it had no test: a NUL guard written as `match("\0")` rejected every path, because
--- Lua 5.1 patterns cannot contain an embedded zero and the pattern parsed as the empty one.
local window = require("vibing.infrastructure.rpc.handlers.window")

describe("win_open_file", function()
  local tmp_file
  local original_win
  local target_win
  local created_bufs = {}

  before_each(function()
    tmp_file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "-- opened by the spec", "return {}" }, tmp_file)

    original_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    target_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(original_win)
  end)

  after_each(function()
    if target_win and vim.api.nvim_win_is_valid(target_win) and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(target_win, true)
    end
    for _, buf in ipairs(created_bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    created_bufs = {}
    if tmp_file then
      vim.fn.delete(tmp_file)
    end
  end)

  it("opens an ordinary path", function()
    -- The regression: this errored with "contains null character" for every path.
    local result = window.win_open_file({ winnr = target_win, filepath = tmp_file })

    assert.is_true(result.success)
    table.insert(created_bufs, result.bufnr)
    -- resolve() on both sides: tempname() hands back /var/... while the buffer name comes back
    -- as /private/var/... on macOS.
    assert.equals(vim.fn.resolve(tmp_file), vim.fn.resolve(vim.api.nvim_buf_get_name(result.bufnr)))
    assert.equals(result.bufnr, vim.api.nvim_win_get_buf(target_win))
  end)

  it("leaves focus where it was", function()
    -- The tour narrates from the chat window; stealing focus would move the user's cursor.
    local result = window.win_open_file({ winnr = target_win, filepath = tmp_file })
    table.insert(created_bufs, result.bufnr)

    assert.equals(original_win, vim.api.nvim_get_current_win())
  end)

  it("still rejects a path that really does contain a NUL", function()
    local ok, err = pcall(window.win_open_file, { winnr = target_win, filepath = "/tmp/a\0b.lua" })

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("null character", 1, true))
  end)

  it("rejects an empty or whitespace-only path", function()
    assert.is_false(pcall(window.win_open_file, { winnr = target_win, filepath = "" }))
    assert.is_false(pcall(window.win_open_file, { winnr = target_win, filepath = "   " }))
  end)

  it("rejects a missing parameter and an invalid window", function()
    assert.is_false(pcall(window.win_open_file, { winnr = target_win }))
    assert.is_false(pcall(window.win_open_file, { filepath = tmp_file }))
    assert.is_false(pcall(window.win_open_file, { winnr = 999999, filepath = tmp_file }))
  end)
end)
