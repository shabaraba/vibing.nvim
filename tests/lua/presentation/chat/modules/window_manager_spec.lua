-- Tests for vibing.presentation.chat.modules.window_manager

local window_manager = require("vibing.presentation.chat.modules.window_manager")

describe("window_manager._resolve_size", function()
  local resolve = window_manager._resolve_size

  it("treats a value below 1 as a ratio of the screen", function()
    assert.equals(40, resolve(0.4, 100, 0.5))
    assert.equals(24, resolve(0.8, 30, 0.5))
  end)

  it("treats 1 or above as an absolute cell count", function()
    -- The bug this covers: `width = 80` used to be multiplied by the screen width.
    assert.equals(80, resolve(80, 200, 0.4))
    assert.equals(1, resolve(1, 200, 0.4))
  end)

  it("falls back to the default ratio when the value is nil", function()
    assert.equals(40, resolve(nil, 100, 0.4))
    assert.equals(80, resolve(nil, 100, 0.8))
  end)

  it("clamps to the screen so an oversized absolute value cannot break nvim_open_win", function()
    assert.equals(100, resolve(500, 100, 0.4))
  end)

  it("never resolves to zero or a negative size", function()
    assert.equals(1, resolve(0, 100, 0.4))
    assert.equals(1, resolve(0.001, 100, 0.4))
    assert.equals(1, resolve(-5, 100, 0.4))
  end)

  it("truncates fractional absolute values", function()
    assert.equals(80, resolve(80.9, 200, 0.4))
  end)
end)

describe("window_manager.create_window", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("honours an absolute width on the vertical splits", function()
    for _, position in ipairs({ "right", "left" }) do
      local win = window_manager.create_window(buf, { position = position, width = 30 })
      assert.is_not_nil(win, position)
      assert.equals(30, vim.api.nvim_win_get_width(win), position)
      vim.api.nvim_win_close(win, true)
    end
  end)

  it("honours an absolute height on the horizontal splits", function()
    -- top/bottom are the only positions that feed `height` to :resize, so they need their own
    -- coverage even though resolve_size is shared.
    for _, position in ipairs({ "top", "bottom" }) do
      local win = window_manager.create_window(buf, { position = position, height = 8 })
      assert.is_not_nil(win, position)
      assert.equals(8, vim.api.nvim_win_get_height(win), position)
      vim.api.nvim_win_close(win, true)
    end
  end)

  it("honours the configured height on a float instead of the hardcoded 0.8", function()
    local win = window_manager.create_window(buf, { position = "float", width = 40, height = 10 })
    assert.is_not_nil(win)
    assert.equals(10, vim.api.nvim_win_get_height(win))
    assert.equals(40, vim.api.nvim_win_get_width(win))
    vim.api.nvim_win_close(win, true)
  end)

  it("still defaults a float to 0.8 of the screen when height is unset", function()
    local win = window_manager.create_window(buf, { position = "float", width = 40 })
    assert.is_not_nil(win)
    assert.equals(math.floor(vim.o.lines * 0.8), vim.api.nvim_win_get_height(win))
    vim.api.nvim_win_close(win, true)
  end)

  it("returns nil for the buffer-only 'back' position", function()
    assert.is_nil(window_manager.create_window(buf, { position = "back", width = 0.4 }))
  end)
end)
