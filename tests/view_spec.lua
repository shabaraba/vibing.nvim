-- Tests for vibing.presentation.chat.view
-- Regression: a chat buffer created earlier must still be recognized as a
-- chat buffer after a newer chat becomes the most-recently-rendered one.

describe("vibing.presentation.chat.view", function()
  local view

  before_each(function()
    package.loaded["vibing.presentation.chat.view"] = nil
    require("vibing").setup({})
    view = require("vibing.presentation.chat.view")
    view._attached_buffers = {}
    view._current_buffer = nil
  end)

  after_each(function()
    for bufnr, _ in pairs(view._attached_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    view._attached_buffers = {}
    view._current_buffer = nil
  end)

  describe("render", function()
    it("tracks every rendered chat buffer, not just the most recent one", function()
      view.render({ session_id = "session-1" }, "back")
      local first_buf = view._current_buffer.buf

      view.render({ session_id = "session-2" }, "back")

      assert.is_not_nil(view._attached_buffers[first_buf])
    end)
  end)

  describe("is_current_buffer_chat", function()
    it("recognizes an older chat buffer after a newer chat becomes current", function()
      view.render({ session_id = "session-1" }, "back")
      local first_buf = view._current_buffer.buf

      view.render({ session_id = "session-2" }, "back")

      vim.api.nvim_set_current_buf(first_buf)

      assert.is_true(view.is_current_buffer_chat())
    end)
  end)
end)
