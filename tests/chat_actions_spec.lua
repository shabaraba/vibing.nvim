-- Tests for vibing.actions.chat module

describe("vibing.actions.chat", function()
  local ChatActions
  local mock_vibing
  local mock_config
  local mock_chat_buffer
  local mock_adapter

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.actions.chat"] = nil
    package.loaded["vibing"] = nil
    package.loaded["vibing.context"] = nil
    package.loaded["vibing.ui.chat_buffer"] = nil
    package.loaded["vibing.context.formatter"] = nil

    -- Setup mock config
    mock_config = {
      chat = {
        window = {
          width = 0.5,
          position = "float",
          border = "rounded",
        },
        save_location_type = "user",
        auto_context = true,
        context_position = "after",
      },
    }

    -- Mock chat buffer
    mock_chat_buffer = {
      open = function() end,
      close = function() end,
      is_open = function() return false end,
      load_from_file = function() return true end,
      _create_window = function() end,
      _setup_keymaps = function() end,
      parse_frontmatter = function() return {} end,
      get_session_id = function() return nil end,
      update_session_id = function() end,
      extract_conversation = function() return {} end,
      update_filename_from_message = function() end,
      start_response = function() end,
      append_chunk = function() end,
      add_user_section = function() end,
      buf = nil,
      win = nil,
      file_path = nil,
      session_id = nil,
    }

    -- Mock adapter
    mock_adapter = {
      supports = function(feature)
        if feature == "streaming" then return true end
        if feature == "session" then return true end
        return false
      end,
      stream = function(prompt, opts, on_chunk, on_done)
        -- Simulate successful streaming
        vim.schedule(function()
          on_chunk("Test response")
          on_done({ content = "Test response" })
        end)
      end,
      execute = function(prompt, opts)
        return { content = "Test response" }
      end,
      set_session_id = function() end,
      get_session_id = function() return "test-session-123" end,
    }

    -- Mock vibing module
    mock_vibing = {
      get_config = function()
        return mock_config
      end,
      get_adapter = function()
        return mock_adapter
      end,
    }
    package.loaded["vibing"] = mock_vibing

    -- Mock context module
    package.loaded["vibing.context"] = {
      get_all = function() return {} end,
    }

    -- Mock chat buffer constructor
    package.loaded["vibing.ui.chat_buffer"] = {
      new = function()
        return mock_chat_buffer
      end,
    }

    -- Mock formatter
    package.loaded["vibing.context.formatter"] = {
      format_prompt = function(message, contexts, position)
        return message
      end,
    }

    ChatActions = require("vibing.actions.chat")
  end)

  after_each(function()
    -- Reset module state
    if ChatActions then
      ChatActions.chat_buffer = nil
    end
  end)

  describe("open", function()
    it("should create and open chat buffer", function()
      local opened = false
      mock_chat_buffer.open = function()
        opened = true
      end

      ChatActions.open()

      assert.is_true(opened)
      assert.is_not_nil(ChatActions.chat_buffer)
    end)

    it("should reuse existing chat buffer", function()
      ChatActions.chat_buffer = mock_chat_buffer
      local first_buffer = ChatActions.chat_buffer

      ChatActions.open()

      assert.equals(first_buffer, ChatActions.chat_buffer)
    end)
  end)

  describe("close", function()
    it("should close existing chat buffer", function()
      local closed = false
      mock_chat_buffer.close = function()
        closed = true
      end
      ChatActions.chat_buffer = mock_chat_buffer

      ChatActions.close()

      assert.is_true(closed)
    end)

    it("should handle no active buffer", function()
      ChatActions.chat_buffer = nil
      ChatActions.close() -- Should not error
      assert.is_nil(ChatActions.chat_buffer)
    end)
  end)

  describe("toggle", function()
    it("should open when closed", function()
      local opened = false
      mock_chat_buffer.is_open = function() return false end
      mock_chat_buffer.open = function() opened = true end

      ChatActions.toggle()

      assert.is_true(opened)
    end)

    it("should close when open", function()
      local closed = false
      mock_chat_buffer.is_open = function() return true end
      mock_chat_buffer.close = function() closed = true end
      ChatActions.chat_buffer = mock_chat_buffer

      ChatActions.toggle()

      assert.is_true(closed)
    end)
  end)

  describe("open_file", function()
    it("should load chat from file", function()
      local loaded = false
      local window_created = false
      local keymaps_setup = false

      mock_chat_buffer.load_from_file = function(path)
        loaded = true
        return true
      end
      mock_chat_buffer._create_window = function()
        window_created = true
      end
      mock_chat_buffer._setup_keymaps = function()
        keymaps_setup = true
      end

      ChatActions.open_file("/path/to/chat.md")

      assert.is_true(loaded)
      assert.is_true(window_created)
      assert.is_true(keymaps_setup)
    end)

    it("should handle load failure", function()
      mock_chat_buffer.load_from_file = function()
        return false
      end

      -- Should not error, just notify
      ChatActions.open_file("/nonexistent.md")
    end)
  end)

  describe("attach_to_buffer", function()
    it("should attach to existing buffer", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "---",
        "session_id: test-123",
        "---",
      })

      local keymaps_setup = false
      mock_chat_buffer._setup_keymaps = function()
        keymaps_setup = true
      end

      ChatActions.attach_to_buffer(buf, "/path/to/chat.md")

      assert.is_not_nil(ChatActions.chat_buffer)
      assert.equals(buf, ChatActions.chat_buffer.buf)
      assert.equals("/path/to/chat.md", ChatActions.chat_buffer.file_path)
      assert.is_true(keymaps_setup)

      -- Cleanup
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("send", function()
    it("should call adapter methods correctly", function()
      local message_sent = false
      local response_started = false

      local test_buffer = {}
      for k, v in pairs(mock_chat_buffer) do
        test_buffer[k] = v
      end

      test_buffer.start_response = function()
        response_started = true
      end

      package.loaded["vibing"].get_adapter = function()
        return {
          supports = function(feature)
            return feature == "streaming"
          end,
          stream = function(prompt, opts, on_chunk, on_done)
            message_sent = true
            -- Prompt is formatted, so just check it's a string
            assert.is_string(prompt)
            vim.schedule(function()
              on_done({ content = "Response" })
            end)
          end,
          set_session_id = function() end,
          get_session_id = function() return nil end,
        }
      end

      ChatActions.send(test_buffer, "Hello")

      -- Wait briefly for async
      vim.wait(100, function() return message_sent end)

      assert.is_true(message_sent)
      assert.is_true(response_started)
    end)

    it("should handle no adapter", function()
      mock_vibing.get_adapter = function()
        return nil
      end

      -- Should not error, just notify
      ChatActions.send(mock_chat_buffer, "Hello")
    end)

    it("should sync session ID from buffer to adapter", function()
      local session_set = false

      local test_buffer = {}
      for k, v in pairs(mock_chat_buffer) do
        test_buffer[k] = v
      end
      test_buffer.get_session_id = function()
        return "saved-session-456"
      end

      package.loaded["vibing"].get_adapter = function()
        return {
          supports = function(f) return f == "session" or f == "streaming" end,
          stream = function(prompt, opts, on_chunk, on_done)
            vim.schedule(function()
              on_done({ content = "Response" })
            end)
          end,
          execute = function(prompt, opts)
            return { content = "Response" }
          end,
          set_session_id = function(sid)
            session_set = true
            assert.equals("saved-session-456", sid)
          end,
          get_session_id = function() return "saved-session-456" end,
        }
      end

      ChatActions.send(test_buffer, "Resume")

      -- Wait for async
      vim.wait(100)

      assert.is_true(session_set)
    end)

    it("should update filename for first message", function()
      local filename_updated = false
      local updated_message = nil

      local test_buffer = {}
      for k, v in pairs(mock_chat_buffer) do
        test_buffer[k] = v
      end
      test_buffer.extract_conversation = function()
        return {} -- Empty conversation = first message
      end
      test_buffer.update_filename_from_message = function(msg)
        filename_updated = true
        updated_message = msg
      end

      package.loaded["vibing"].get_adapter = function()
        return {
          supports = function() return true end,
          stream = function(prompt, opts, on_chunk, on_done)
            vim.schedule(function()
              on_done({ content = "Response" })
            end)
          end,
          set_session_id = function() end,
          get_session_id = function() return nil end,
        }
      end

      ChatActions.send(test_buffer, "First message")

      -- Wait for async
      vim.wait(100)

      assert.is_true(filename_updated)
      assert.equals("First message", updated_message)
    end)
  end)

  describe("integration", function()
    it("should handle full chat lifecycle", function()
      -- Open
      ChatActions.open()
      assert.is_not_nil(ChatActions.chat_buffer)

      -- Close
      ChatActions.close()

      -- Toggle (should reopen)
      ChatActions.toggle()

      -- No errors expected
    end)
  end)
end)
