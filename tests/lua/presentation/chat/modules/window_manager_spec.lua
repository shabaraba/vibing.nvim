-- Tests for vibing.presentation.chat.modules.window_manager

local window_manager = require("vibing.presentation.chat.modules.window_manager")

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

  -- These three go through "float" because nvim_open_win is the call that actually rejects an
  -- out-of-range size; :resize would silently clamp for us and hide a missing guard.
  it("clamps an oversized absolute size instead of failing nvim_open_win", function()
    local win = window_manager.create_window(buf, { position = "float", width = 5000, height = 5000 })
    assert.equals(vim.o.columns, vim.api.nvim_win_get_width(win))
    assert.equals(vim.o.lines, vim.api.nvim_win_get_height(win))
    vim.api.nvim_win_close(win, true)
  end)

  it("never resolves to a zero or negative size", function()
    for _, size in ipairs({ 0, -5 }) do
      local win = window_manager.create_window(buf, { position = "float", width = size, height = size })
      assert.equals(1, vim.api.nvim_win_get_width(win), tostring(size))
      assert.equals(1, vim.api.nvim_win_get_height(win), tostring(size))
      vim.api.nvim_win_close(win, true)
    end
  end)

  it("truncates a fractional absolute size", function()
    local win = window_manager.create_window(buf, { position = "float", width = 30.9, height = 10.9 })
    assert.equals(30, vim.api.nvim_win_get_width(win))
    assert.equals(10, vim.api.nvim_win_get_height(win))
    vim.api.nvim_win_close(win, true)
  end)
end)

describe("window_manager.create_window through config.setup", function()
  -- The tests above hand create_window a raw table, so they cannot see what setup()'s default
  -- merge actually delivers.
  local config = require("vibing.config")
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    config.setup({})
  end)

  it("gives a float 0.8 of the screen when the user only picks the position", function()
    config.setup({ chat = { window = { position = "float" } } })

    local win = window_manager.create_window(buf, config.get().chat.window)
    assert.equals(math.floor(vim.o.lines * 0.8), vim.api.nvim_win_get_height(win))
    vim.api.nvim_win_close(win, true)
  end)

  it("gives a bottom split 0.4 of the screen when the user only picks the position", function()
    config.setup({ chat = { window = { position = "bottom" } } })

    local win = window_manager.create_window(buf, config.get().chat.window)
    assert.equals(math.floor(vim.o.lines * 0.4), vim.api.nvim_win_get_height(win))
    vim.api.nvim_win_close(win, true)
  end)

  it("lets an explicit height win for both", function()
    config.setup({ chat = { window = { position = "float", height = 12 } } })
    local float_win = window_manager.create_window(buf, config.get().chat.window)
    assert.equals(12, vim.api.nvim_win_get_height(float_win))
    vim.api.nvim_win_close(float_win, true)

    config.setup({ chat = { window = { position = "bottom", height = 12 } } })
    local split_win = window_manager.create_window(buf, config.get().chat.window)
    assert.equals(12, vim.api.nvim_win_get_height(split_win))
    vim.api.nvim_win_close(split_win, true)
  end)
end)
