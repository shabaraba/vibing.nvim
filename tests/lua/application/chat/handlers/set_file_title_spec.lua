describe("set_file_title handler - streaming guard", function()
  local handler

  before_each(function()
    package.loaded["vibing.application.chat.handlers.set_file_title"] = nil
    handler = require("vibing.application.chat.handlers.set_file_title")
  end)

  after_each(function()
    package.loaded["vibing.application.chat.handlers.set_file_title"] = nil
  end)

  it("returns false and skips title generation while the main response is streaming", function()
    local generate_called = false
    local original_generate = require("vibing.core.utils.title_generator").generate_from_conversation
    require("vibing.core.utils.title_generator").generate_from_conversation = function()
      generate_called = true
    end

    local buf = vim.api.nvim_create_buf(false, true)
    local chat_buffer = {
      buf = buf,
      is_sending = function()
        return true
      end,
      extract_conversation = function()
        return { { role = "user", content = "hi" } }
      end,
    }

    local ok = handler({}, chat_buffer)

    assert.is_false(ok)
    assert.is_false(generate_called)

    require("vibing.core.utils.title_generator").generate_from_conversation = original_generate
  end)

  it("proceeds to title generation when not sending", function()
    local generate_called = false
    local original_generate = require("vibing.core.utils.title_generator").generate_from_conversation
    require("vibing.core.utils.title_generator").generate_from_conversation = function()
      generate_called = true
    end

    local buf = vim.api.nvim_create_buf(false, true)
    local chat_buffer = {
      buf = buf,
      is_sending = function()
        return false
      end,
      extract_conversation = function()
        return { { role = "user", content = "hi" } }
      end,
      get_session_id = function()
        return nil
      end,
    }

    handler({}, chat_buffer)

    assert.is_true(generate_called)

    require("vibing.core.utils.title_generator").generate_from_conversation = original_generate
  end)
end)
