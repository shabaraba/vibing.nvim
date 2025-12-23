-- Tests for vibing.ui.chat_buffer module

describe("vibing.ui.chat_buffer", function()
  local ChatBuffer
  local mock_config
  local original_vibing

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.ui.chat_buffer"] = nil
    package.loaded["vibing.context"] = nil
    package.loaded["vibing"] = nil

    -- Mock context module
    package.loaded["vibing.context"] = {
      add = function() end,
      get_all = function() return {} end,
    }

    -- Mock vibing module
    original_vibing = package.loaded["vibing"]
    mock_config = {
      agent = {
        default_mode = "code",
        default_model = "sonnet",
      },
      keymaps = {
        send = "<CR>",
        cancel = "<C-c>",
        add_context = "<C-f>",
      },
      window = {
        width = 0.5,
        position = "float",
        border = "rounded",
      },
      save_location_type = "user",
    }

    package.loaded["vibing"] = {
      get_config = function()
        return mock_config
      end,
      get_adapter = function()
        return {
          cancel = function() end,
        }
      end,
    }

    ChatBuffer = require("vibing.ui.chat_buffer")
  end)

  after_each(function()
    package.loaded["vibing"] = original_vibing
  end)

  describe("new", function()
    it("should create chat buffer instance", function()
      local chat = ChatBuffer:new(mock_config)
      assert.is_not_nil(chat)
      assert.is_nil(chat.buf)
      assert.is_nil(chat.win)
      assert.equals(mock_config, chat.config)
      assert.is_nil(chat.session_id)
      assert.is_nil(chat.file_path)
    end)
  end)

  describe("_get_save_directory", function()
    it("should return user directory for user location type", function()
      local chat = ChatBuffer:new({ save_location_type = "user" })
      local dir = chat:_get_save_directory()
      assert.is_not_nil(dir:match("vibing/chats/$"))
    end)

    it("should return project directory for project location type", function()
      local chat = ChatBuffer:new({ save_location_type = "project" })
      local dir = chat:_get_save_directory()
      assert.is_not_nil(dir:match("%.vibing/chat/$"))
    end)

    it("should return custom directory for custom location type", function()
      local custom_path = "/tmp/custom/path"
      local chat = ChatBuffer:new({
        save_location_type = "custom",
        save_dir = custom_path,
      })
      local dir = chat:_get_save_directory()
      assert.equals(custom_path .. "/", dir)
    end)

    it("should add trailing slash if missing for custom path", function()
      local chat = ChatBuffer:new({
        save_location_type = "custom",
        save_dir = "/tmp/no-slash",
      })
      local dir = chat:_get_save_directory()
      assert.equals("/tmp/no-slash/", dir)
    end)
  end)

  describe("parse_frontmatter", function()
    it("should parse YAML frontmatter from buffer", function()
      local chat = ChatBuffer:new(mock_config)

      -- Create a buffer with frontmatter
      chat.buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(chat.buf, 0, -1, false, {
        "---",
        "session_id: test-session-123",
        "created_at: 2024-01-01T12:00:00",
        "mode: code",
        "---",
        "",
        "# Chat content",
      })

      local result = chat:parse_frontmatter()

      assert.equals("test-session-123", result.session_id)
      assert.equals("2024-01-01T12:00:00", result.created_at)
      assert.equals("code", result.mode)

      -- Cleanup
      vim.api.nvim_buf_delete(chat.buf, { force = true })
    end)

    it("should return empty table if no buffer", function()
      local chat = ChatBuffer:new(mock_config)
      local result = chat:parse_frontmatter()
      assert.same({}, result)
    end)
  end)

  describe("get_session_id", function()
    it("should return stored session_id", function()
      local chat = ChatBuffer:new(mock_config)
      chat.session_id = "test-session-456"

      assert.equals("test-session-456", chat:get_session_id())
    end)

    it("should return nil if no session_id", function()
      local chat = ChatBuffer:new(mock_config)
      assert.is_nil(chat:get_session_id())
    end)
  end)

  describe("extract_user_message", function()
    it("should extract message from markdown format", function()
      local chat = ChatBuffer:new(mock_config)

      -- Create a buffer with user message
      chat.buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(chat.buf, 0, -1, false, {
        "---",
        "session_id: test",
        "---",
        "",
        "## User",
        "",
        "Hello world",
        "This is my message",
        "",
        "## Assistant",
      })

      local result = chat:extract_user_message()
      assert.is_not_nil(result)
      assert.is_not_nil(result:match("Hello world"))
      assert.is_not_nil(result:match("This is my message"))

      -- Cleanup
      vim.api.nvim_buf_delete(chat.buf, { force = true })
    end)

    it("should return nil if no user message", function()
      local chat = ChatBuffer:new(mock_config)

      -- Create buffer without user section
      chat.buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(chat.buf, 0, -1, false, {
        "---",
        "session_id: test",
        "---",
      })

      local result = chat:extract_user_message()
      assert.is_nil(result)

      -- Cleanup
      vim.api.nvim_buf_delete(chat.buf, { force = true })
    end)
  end)

  describe("integration", function()
    it("should handle full lifecycle without errors", function()
      local chat = ChatBuffer:new(mock_config)

      -- Create buffer and test parse_frontmatter
      chat.buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(chat.buf, 0, -1, false, {
        "---",
        "session_id: test-session",
        "mode: code",
        "---",
      })

      local frontmatter = chat:parse_frontmatter()
      assert.equals("test-session", frontmatter.session_id)
      assert.equals("code", frontmatter.mode)

      -- Test session management
      chat.session_id = "session-123"
      assert.equals("session-123", chat:get_session_id())

      -- Cleanup
      vim.api.nvim_buf_delete(chat.buf, { force = true })
    end)
  end)
end)
