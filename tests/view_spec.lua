-- Tests for vibing.presentation.chat.view
-- Regression: a chat buffer created earlier must still be recognized as a
-- chat buffer after a newer chat becomes the most-recently-rendered one.

local ChatBuffers = require("tests.helpers.chat_buffers")

describe("vibing.presentation.chat.view", function()
  local view

  before_each(function()
    package.loaded["vibing.presentation.chat.view"] = nil
    ChatBuffers.setup()
    view = require("vibing.presentation.chat.view")
  end)

  after_each(ChatBuffers.reset)

  describe("render", function()
    it("tracks every rendered chat buffer, not just the most recent one", function()
      view.render({ session_id = "session-1" }, "back")
      local first_buf = view._current_buffer.buf

      view.render({ session_id = "session-2" }, "back")

      assert.is_not_nil(view._attached_buffers[first_buf])
    end)

    it("returns the chat buffer it created", function()
      local chat_buf = view.render({ session_id = "session-1" }, "back")

      assert.is_not_nil(chat_buf)
      assert.equals(view._current_buffer.buf, chat_buf.buf)
    end)

    it("does not leak a one-off position into the global config", function()
      -- ChatBuffer holds a reference to config.chat, so overriding the position in place used to
      -- change the user's default for the rest of the session — right down to Config.defaults,
      -- which survives a later setup(). nvim_chat_create always renders "back", which would have
      -- left every subsequent :VibingChat opening no window at all.
      -- Asserting the literal "current" rather than a value read beforehand is deliberate: a
      -- leak from an earlier render in this file would have made the read-first form pass.
      local config = require("vibing").get_config()

      local chat_buf = view.render({ session_id = "session-1" }, "back")

      assert.equals("back", chat_buf.config.window.position)
      assert.equals("current", config.chat.window.position)
      assert.equals("current", require("vibing.config").defaults.chat.window.position)
      assert.is_false(chat_buf.config.window == config.chat.window)
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

    it("self-heals: attaches an unattached chat file on demand", function()
      -- Simulate the live failure: a chat file is open but was never attached
      -- (detection autocmd never fired). The command entry path must still
      -- recognize it by attaching on demand rather than reporting "not a chat".
      local dir = "/tmp/vibing_selfheal/.vibing/chat"
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/chat-selfheal.md"
      vim.fn.writefile({ "---", "vibing.nvim: true", "---", "# Vibing Chat" }, path)

      vim.cmd("edit " .. path)
      local buf = vim.api.nvim_get_current_buf()
      assert.is_nil(view._attached_buffers[buf])

      assert.is_true(view.is_current_buffer_chat())
      assert.is_not_nil(view._attached_buffers[buf])
    end)
  end)
end)
