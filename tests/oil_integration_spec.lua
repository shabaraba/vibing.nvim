-- Tests for vibing.integrations.oil module

describe("vibing.integrations.oil", function()
  local OilIntegration
  local mock_oil
  local mock_chat

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.integrations.oil"] = nil
    package.loaded["oil"] = nil
    package.loaded["vibing.actions.chat"] = nil

    -- Mock oil.nvim module
    mock_oil = {
      get_current_dir = function()
        return "/test/dir/"
      end,
      get_cursor_entry = function()
        return {
          type = "file",
          name = "test.lua",
        }
      end,
    }

    -- Mock chat module
    mock_chat = {
      chat_buffer = nil,
      open = function() end,
    }

    OilIntegration = require("vibing.integrations.oil")
  end)

  describe("is_available", function()
    it("should return true when oil.nvim is available", function()
      package.loaded["oil"] = mock_oil

      local result = OilIntegration.is_available()

      assert.is_true(result)
    end)

    it("should return false when oil.nvim is not available", function()
      package.loaded["oil"] = nil

      local result = OilIntegration.is_available()

      assert.is_false(result)
    end)
  end)

  describe("is_oil_buffer", function()
    it("should return true when in oil buffer", function()
      package.loaded["oil"] = mock_oil
      mock_oil.get_current_dir = function()
        return "/test/dir/"
      end

      local result = OilIntegration.is_oil_buffer()

      assert.is_true(result)
    end)

    it("should return false when oil is not available", function()
      package.loaded["oil"] = nil

      local result = OilIntegration.is_oil_buffer()

      assert.is_false(result)
    end)

    it("should return false when not in oil buffer", function()
      package.loaded["oil"] = mock_oil
      mock_oil.get_current_dir = function()
        return nil
      end

      local result = OilIntegration.is_oil_buffer()

      assert.is_false(result)
    end)
  end)

  describe("get_cursor_file", function()
    it("should return nil when not in oil buffer", function()
      package.loaded["oil"] = mock_oil
      mock_oil.get_current_dir = function()
        return nil
      end

      local result = OilIntegration.get_cursor_file()

      assert.is_nil(result)
    end)

    it("should return nil when cursor entry is nil", function()
      package.loaded["oil"] = mock_oil
      mock_oil.get_cursor_entry = function()
        return nil
      end

      local result = OilIntegration.get_cursor_file()

      assert.is_nil(result)
    end)

    it("should return nil when cursor is on directory", function()
      package.loaded["oil"] = mock_oil
      mock_oil.get_cursor_entry = function()
        return {
          type = "directory",
          name = "subdir",
        }
      end

      local result = OilIntegration.get_cursor_file()

      assert.is_nil(result)
    end)

    it("should return nil when current_dir is nil", function()
      package.loaded["oil"] = mock_oil
      mock_oil.get_current_dir = function()
        return nil
      end

      local result = OilIntegration.get_cursor_file()

      assert.is_nil(result)
    end)

    it("should return file path when cursor is on file", function()
      package.loaded["oil"] = mock_oil
      mock_oil.get_current_dir = function()
        return "/test/dir/"
      end
      mock_oil.get_cursor_entry = function()
        return {
          type = "file",
          name = "test.lua",
        }
      end

      local result = OilIntegration.get_cursor_file()

      assert.equals("/test/dir/test.lua", result)
    end)

    it("should add trailing slash if missing", function()
      package.loaded["oil"] = mock_oil
      mock_oil.get_current_dir = function()
        return "/test/dir"
      end
      mock_oil.get_cursor_entry = function()
        return {
          type = "file",
          name = "test.lua",
        }
      end

      local result = OilIntegration.get_cursor_file()

      assert.equals("/test/dir/test.lua", result)
    end)
  end)

  describe("get_selected_files", function()
    it("should return empty array when no file at cursor", function()
      package.loaded["oil"] = mock_oil
      mock_oil.get_cursor_entry = function()
        return nil
      end

      local result = OilIntegration.get_selected_files()

      assert.same({}, result)
    end)

    it("should return array with file when cursor is on file", function()
      package.loaded["oil"] = mock_oil
      mock_oil.get_current_dir = function()
        return "/test/dir/"
      end
      mock_oil.get_cursor_entry = function()
        return {
          type = "file",
          name = "test.lua",
        }
      end

      local result = OilIntegration.get_selected_files()

      assert.same({ "/test/dir/test.lua" }, result)
    end)
  end)

  describe("send_to_chat", function()
    local original_notify
    local original_filereadable
    local original_getcwd
    local original_buf_get_lines
    local original_buf_set_lines
    local original_win_set_cursor
    local notify_messages

    before_each(function()
      package.loaded["oil"] = mock_oil
      package.loaded["vibing.actions.chat"] = mock_chat

      -- Mock vim.notify
      original_notify = vim.notify
      notify_messages = {}
      vim.notify = function(msg, level)
        table.insert(notify_messages, { msg = msg, level = level })
      end

      -- Mock vim.fn.filereadable
      original_filereadable = vim.fn.filereadable
      vim.fn.filereadable = function()
        return 1
      end

      -- Mock vim.fn.getcwd
      original_getcwd = vim.fn.getcwd
      vim.fn.getcwd = function()
        return "/test/dir"
      end

      -- Mock vim.api buffer operations
      original_buf_get_lines = vim.api.nvim_buf_get_lines
      vim.api.nvim_buf_get_lines = function()
        return { "line1", "line2" }
      end

      original_buf_set_lines = vim.api.nvim_buf_set_lines
      vim.api.nvim_buf_set_lines = function() end

      original_win_set_cursor = vim.api.nvim_win_set_cursor
      vim.api.nvim_win_set_cursor = function() end
    end)

    after_each(function()
      -- Restore
      vim.notify = original_notify
      vim.fn.filereadable = original_filereadable
      vim.fn.getcwd = original_getcwd
      vim.api.nvim_buf_get_lines = original_buf_get_lines
      vim.api.nvim_buf_set_lines = original_buf_set_lines
      vim.api.nvim_win_set_cursor = original_win_set_cursor
    end)

    it("should warn when not in oil buffer", function()
      mock_oil.get_current_dir = function()
        return nil
      end

      OilIntegration.send_to_chat()

      assert.equals(1, #notify_messages)
      assert.is_not_nil(notify_messages[1].msg:match("Not in an oil.nvim buffer"))
      assert.equals(vim.log.levels.WARN, notify_messages[1].level)
    end)

    it("should warn when no file selected", function()
      mock_oil.get_cursor_entry = function()
        return {
          type = "directory",
          name = "subdir",
        }
      end

      OilIntegration.send_to_chat()

      assert.equals(1, #notify_messages)
      assert.is_not_nil(notify_messages[1].msg:match("No file selected"))
    end)

    it("should open chat if not open", function()
      local open_called = false
      mock_chat.open = function()
        open_called = true
      end
      mock_chat.chat_buffer = {
        is_open = function()
          return false
        end,
        get_buffer = function()
          return 1
        end,
        win = 1,
      }

      OilIntegration.send_to_chat()

      assert.is_true(open_called)
    end)

    it("should warn when file is not readable", function()
      vim.fn.filereadable = function()
        return 0
      end

      mock_chat.chat_buffer = {
        is_open = function()
          return true
        end,
        get_buffer = function()
          return 1
        end,
        win = 1,
      }

      OilIntegration.send_to_chat()

      local has_warning = false
      for _, msg in ipairs(notify_messages) do
        if msg.msg:match("File not readable") then
          has_warning = true
        end
      end
      assert.is_true(has_warning)
    end)

    it("should insert file mention in chat buffer", function()
      local inserted_lines = nil
      vim.api.nvim_buf_set_lines = function(buf, start, end_, strict, lines)
        inserted_lines = lines
      end

      mock_chat.chat_buffer = {
        is_open = function()
          return true
        end,
        get_buffer = function()
          return 1
        end,
        win = 1,
      }

      OilIntegration.send_to_chat()

      assert.is_not_nil(inserted_lines)
      assert.equals(1, #inserted_lines)
      assert.equals("@file:test.lua", inserted_lines[1])
    end)

    it("should convert to relative path", function()
      local inserted_lines = nil
      vim.api.nvim_buf_set_lines = function(buf, start, end_, strict, lines)
        inserted_lines = lines
      end

      vim.fn.getcwd = function()
        return "/test/dir"
      end

      mock_oil.get_current_dir = function()
        return "/test/dir/subdir/"
      end
      mock_oil.get_cursor_entry = function()
        return {
          type = "file",
          name = "file.lua",
        }
      end

      mock_chat.chat_buffer = {
        is_open = function()
          return true
        end,
        get_buffer = function()
          return 1
        end,
        win = 1,
      }

      OilIntegration.send_to_chat()

      assert.is_not_nil(inserted_lines)
      assert.equals("@file:subdir/file.lua", inserted_lines[1])
    end)

    it("should notify success with added count", function()
      mock_chat.chat_buffer = {
        is_open = function()
          return true
        end,
        get_buffer = function()
          return 1
        end,
        win = 1,
      }

      OilIntegration.send_to_chat()

      local has_success = false
      for _, msg in ipairs(notify_messages) do
        if msg.msg:match("Added 1 file%(s%) to chat") then
          has_success = true
        end
      end
      assert.is_true(has_success)
    end)

    it("should handle chat buffer get failure", function()
      mock_chat.chat_buffer = {
        is_open = function()
          return true
        end,
        get_buffer = function()
          return nil
        end,
      }

      OilIntegration.send_to_chat()

      local has_error = false
      for _, msg in ipairs(notify_messages) do
        if msg.msg:match("Failed to get chat buffer") and msg.level == vim.log.levels.ERROR then
          has_error = true
        end
      end
      assert.is_true(has_error)
    end)
  end)

  describe("integration", function()
    it("should have all expected functions", function()
      assert.is_function(OilIntegration.is_available)
      assert.is_function(OilIntegration.is_oil_buffer)
      assert.is_function(OilIntegration.get_cursor_file)
      assert.is_function(OilIntegration.get_selected_files)
      assert.is_function(OilIntegration.send_to_chat)
    end)
  end)
end)
