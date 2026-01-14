-- Tests for session permission handling in ChatBuffer

describe("ChatBuffer session permissions", function()
  local ChatBuffer
  local mock_config

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.presentation.chat.buffer"] = nil
    package.loaded["vibing.presentation.chat.modules.window_manager"] = nil
    package.loaded["vibing.presentation.chat.modules.file_manager"] = nil
    package.loaded["vibing.presentation.chat.modules.frontmatter_handler"] = nil
    package.loaded["vibing.presentation.chat.modules.renderer"] = nil
    package.loaded["vibing.presentation.chat.modules.streaming_handler"] = nil
    package.loaded["vibing.presentation.chat.modules.conversation_extractor"] = nil
    package.loaded["vibing.presentation.chat.modules.keymap_handler"] = nil

    -- Mock dependencies
    package.loaded["vibing.presentation.chat.modules.window_manager"] = {
      create_window = function() return 1 end,
      apply_wrap_config = function() end,
    }
    package.loaded["vibing.presentation.chat.modules.file_manager"] = {
      get_save_directory = function() return "/tmp/" end,
      generate_unique_filename = function() return "test.vibing" end,
      load_from_file = function() return true end,
      update_filename_from_message = function() end,
    }
    package.loaded["vibing.presentation.chat.modules.frontmatter_handler"] = {
      parse = function() return {} end,
      update_session_id = function() end,
      update_field = function() return true end,
      update_list = function() return true end,
      get_list = function() return {} end,
    }
    package.loaded["vibing.presentation.chat.modules.renderer"] = {
      init_content = function() return 1 end,
      moveCursorToEnd = function() end,
      addUserSection = function() end,
      updateContextLine = function() end,
    }
    package.loaded["vibing.presentation.chat.modules.streaming_handler"] = {
      start_response = function() end,
      flush_chunks = function(_, _, buffer) return buffer end,
    }
    package.loaded["vibing.presentation.chat.modules.conversation_extractor"] = {
      extract_conversation = function() return {} end,
      extract_user_message = function() return "test" end,
      commit_user_message = function() end,
    }
    package.loaded["vibing.presentation.chat.modules.keymap_handler"] = {
      setup = function() end,
    }
    package.loaded["vibing.application.context.manager"] = {
      get_all = function() return {} end,
    }

    mock_config = {
      window = {
        position = "right",
        width = 0.5,
        border = "rounded",
      },
      keymaps = {
        send = "<CR>",
        cancel = "<C-c>",
      },
      chat = {
        save_location_type = "user",
      },
    }

    ChatBuffer = require("vibing.presentation.chat.buffer")
  end)

  describe("update_session_permissions", function()
    it("should add tool with :once suffix for allow_once", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = "WebSearch", input = {}, options = {} }

      buffer:update_session_permissions({ action = "allow_once" })

      local allow_list = buffer:get_session_allow()
      assert.equals(1, #allow_list)
      assert.equals("WebSearch:once", allow_list[1])
    end)

    it("should add tool with :once suffix for deny_once", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = "Bash", input = {}, options = {} }

      buffer:update_session_permissions({ action = "deny_once" })

      local deny_list = buffer:get_session_deny()
      assert.equals(1, #deny_list)
      assert.equals("Bash:once", deny_list[1])
    end)

    it("should add tool for allow_for_session", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = "Edit", input = {}, options = {} }

      buffer:update_session_permissions({ action = "allow_for_session" })

      local allow_list = buffer:get_session_allow()
      assert.equals(1, #allow_list)
      assert.equals("Edit", allow_list[1])
    end)

    it("should add tool for deny_for_session", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = "Write", input = {}, options = {} }

      buffer:update_session_permissions({ action = "deny_for_session" })

      local deny_list = buffer:get_session_deny()
      assert.equals(1, #deny_list)
      assert.equals("Write", deny_list[1])
    end)

    it("should prevent duplicates in allow list", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = "Read", input = {}, options = {} }

      -- Add twice
      buffer:update_session_permissions({ action = "allow_once" })
      buffer:update_session_permissions({ action = "allow_once" })

      local allow_list = buffer:get_session_allow()
      -- Should only have one entry (duplicates prevented)
      assert.equals(1, #allow_list)
    end)

    it("should handle mutual exclusivity for allow_for_session", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = "Grep", input = {}, options = {} }

      -- First deny, then allow
      buffer:update_session_permissions({ action = "deny_for_session" })
      buffer:update_session_permissions({ action = "allow_for_session" })

      local allow_list = buffer:get_session_allow()
      local deny_list = buffer:get_session_deny()

      assert.equals(1, #allow_list)
      assert.equals("Grep", allow_list[1])
      assert.equals(0, #deny_list) -- Should be removed from deny list
    end)

    it("should handle mutual exclusivity for deny_for_session", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = "Glob", input = {}, options = {} }

      -- First allow, then deny
      buffer:update_session_permissions({ action = "allow_for_session" })
      buffer:update_session_permissions({ action = "deny_for_session" })

      local allow_list = buffer:get_session_allow()
      local deny_list = buffer:get_session_deny()

      assert.equals(0, #allow_list) -- Should be removed from allow list
      assert.equals(1, #deny_list)
      assert.equals("Glob", deny_list[1])
    end)

    it("should reject invalid action", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = "Test", input = {}, options = {} }

      -- Should not throw error, just return early
      buffer:update_session_permissions({ action = "invalid_action" })

      local allow_list = buffer:get_session_allow()
      local deny_list = buffer:get_session_deny()

      assert.equals(0, #allow_list)
      assert.equals(0, #deny_list)
    end)

    it("should reject missing tool name", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = nil, input = {}, options = {} }

      buffer:update_session_permissions({ action = "allow_once" })

      local allow_list = buffer:get_session_allow()
      assert.equals(0, #allow_list)
    end)

    it("should reject empty tool name", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = "", input = {}, options = {} }

      buffer:update_session_permissions({ action = "allow_once" })

      local allow_list = buffer:get_session_allow()
      assert.equals(0, #allow_list)
    end)

    it("should reject non-string tool name", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = 123, input = {}, options = {} }

      buffer:update_session_permissions({ action = "allow_once" })

      local allow_list = buffer:get_session_allow()
      assert.equals(0, #allow_list)
    end)
  end)

  describe("get_session_allow and get_session_deny", function()
    it("should return deep copy of allow list", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = "Test", input = {}, options = {} }
      buffer:update_session_permissions({ action = "allow_once" })

      local allow_list1 = buffer:get_session_allow()
      local allow_list2 = buffer:get_session_allow()

      -- Should be different tables (deep copy)
      assert.is_not_equal(allow_list1, allow_list2)
      -- But same content
      assert.equals(allow_list1[1], allow_list2[1])
    end)

    it("should return deep copy of deny list", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = "Test", input = {}, options = {} }
      buffer:update_session_permissions({ action = "deny_once" })

      local deny_list1 = buffer:get_session_deny()
      local deny_list2 = buffer:get_session_deny()

      -- Should be different tables (deep copy)
      assert.is_not_equal(deny_list1, deny_list2)
      -- But same content
      assert.equals(deny_list1[1], deny_list2[1])
    end)

    it("should not allow external mutation of allow list", function()
      local buffer = ChatBuffer:new(mock_config)
      buffer._pending_approval = { tool = "Test", input = {}, options = {} }
      buffer:update_session_permissions({ action = "allow_once" })

      local allow_list = buffer:get_session_allow()
      table.insert(allow_list, "Malicious:once")

      -- Internal list should not be affected
      local internal_list = buffer:get_session_allow()
      assert.equals(1, #internal_list)
    end)
  end)

  describe("_build_approval_input_summary", function()
    it("should build summary for Bash command", function()
      local buffer = ChatBuffer:new(mock_config)
      local summary = buffer:_build_approval_input_summary("Bash", { command = "npm install" })
      assert.equals(" (command: npm install)", summary)
    end)

    it("should build summary for Read file_path", function()
      local buffer = ChatBuffer:new(mock_config)
      local summary = buffer:_build_approval_input_summary("Read", { file_path = "test.lua" })
      assert.equals(" (file: test.lua)", summary)
    end)

    it("should build summary for WebSearch query", function()
      local buffer = ChatBuffer:new(mock_config)
      local summary = buffer:_build_approval_input_summary("WebSearch", { query = "Grok AI 2026" })
      assert.equals(" (query: Grok AI 2026)", summary)
    end)

    it("should return empty string for unknown tool", function()
      local buffer = ChatBuffer:new(mock_config)
      local summary = buffer:_build_approval_input_summary("Unknown", { something = "value" })
      assert.equals("", summary)
    end)

    it("should return empty string for missing input key", function()
      local buffer = ChatBuffer:new(mock_config)
      local summary = buffer:_build_approval_input_summary("Bash", { other_key = "value" })
      assert.equals("", summary)
    end)
  end)
end)
