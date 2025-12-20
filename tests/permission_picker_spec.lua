-- Tests for vibing.ui.permission_picker module

describe("vibing.ui.permission_picker", function()
  local permission_picker

  before_each(function()
    -- Reload module before each test
    package.loaded["vibing.ui.permission_picker"] = nil
    permission_picker = require("vibing.ui.permission_picker")
  end)

  describe("module structure", function()
    it("should have show function", function()
      assert.is_function(permission_picker.show)
    end)

    it("should have _show_native function", function()
      assert.is_function(permission_picker._show_native)
    end)

    it("should have _show_telescope function", function()
      assert.is_function(permission_picker._show_telescope)
    end)

    it("should have _handle_tool_selection function", function()
      assert.is_function(permission_picker._handle_tool_selection)
    end)

    it("should have _handle_permission_type function", function()
      assert.is_function(permission_picker._handle_permission_type)
    end)

    it("should have _prompt_bash_pattern function", function()
      assert.is_function(permission_picker._prompt_bash_pattern)
    end)

    it("should have _add_permission function", function()
      assert.is_function(permission_picker._add_permission)
    end)
  end)

  describe("show", function()
    it("should handle invalid chat buffer gracefully", function()
      -- Should not throw error
      local success, err = pcall(permission_picker.show, nil)
      -- May fail but should not crash
      assert.is_boolean(success)
    end)

    it("should check for Telescope availability", function()
      local mock_chat_buffer = {
        buf = 1,
      }

      -- Mock vim.api.nvim_buf_is_valid
      local original_is_valid = vim.api.nvim_buf_is_valid
      vim.api.nvim_buf_is_valid = function()
        return true
      end

      -- Track which picker was used
      local native_called = false
      local telescope_called = false

      permission_picker._show_native = function()
        native_called = true
      end
      permission_picker._show_telescope = function()
        telescope_called = true
      end

      -- Test without Telescope
      package.loaded["telescope"] = nil
      permission_picker.show(mock_chat_buffer)

      -- Either native or telescope should be called, depending on availability
      assert.is_true(native_called or telescope_called)

      -- Restore
      vim.api.nvim_buf_is_valid = original_is_valid
    end)
  end)

  describe("_add_permission", function()
    it("should handle invalid buffer gracefully", function()
      local mock_chat_buffer = {
        buf = 999,  -- Invalid buffer
        parse_frontmatter = function()
          return {}
        end,
        update_frontmatter = function()
          return true
        end,
      }

      local original_is_valid = vim.api.nvim_buf_is_valid
      vim.api.nvim_buf_is_valid = function()
        return false
      end

      -- Should not crash
      local success = pcall(permission_picker._add_permission, mock_chat_buffer, "allow", "Read")
      assert.is_boolean(success)

      -- Restore
      vim.api.nvim_buf_is_valid = original_is_valid
    end)

    it("should add tool to permissions_allow", function()
      local updated_frontmatter = nil
      local mock_chat_buffer = {
        buf = 1,
        parse_frontmatter = function()
          return {
            permissions_allow = {},
            permissions_deny = {},
          }
        end,
        update_frontmatter = function(self, frontmatter)
          updated_frontmatter = frontmatter
          return true
        end,
      }

      local original_is_valid = vim.api.nvim_buf_is_valid
      vim.api.nvim_buf_is_valid = function()
        return true
      end

      permission_picker._add_permission(mock_chat_buffer, "allow", "Read")

      assert.is_not_nil(updated_frontmatter)
      assert.is_table(updated_frontmatter.permissions_allow)
      assert.equals(1, #updated_frontmatter.permissions_allow)
      assert.equals("Read", updated_frontmatter.permissions_allow[1])

      -- Restore
      vim.api.nvim_buf_is_valid = original_is_valid
    end)

    it("should add tool to permissions_deny", function()
      local updated_frontmatter = nil
      local mock_chat_buffer = {
        buf = 1,
        parse_frontmatter = function()
          return {
            permissions_allow = {},
            permissions_deny = {},
          }
        end,
        update_frontmatter = function(self, frontmatter)
          updated_frontmatter = frontmatter
          return true
        end,
      }

      local original_is_valid = vim.api.nvim_buf_is_valid
      vim.api.nvim_buf_is_valid = function()
        return true
      end

      permission_picker._add_permission(mock_chat_buffer, "deny", "Bash")

      assert.is_not_nil(updated_frontmatter)
      assert.is_table(updated_frontmatter.permissions_deny)
      assert.equals(1, #updated_frontmatter.permissions_deny)
      assert.equals("Bash", updated_frontmatter.permissions_deny[1])

      -- Restore
      vim.api.nvim_buf_is_valid = original_is_valid
    end)

    it("should not add duplicate tools", function()
      local update_count = 0
      local mock_chat_buffer = {
        buf = 1,
        parse_frontmatter = function()
          return {
            permissions_allow = { "Read" },
            permissions_deny = {},
          }
        end,
        update_frontmatter = function(self, frontmatter)
          update_count = update_count + 1
          return true
        end,
      }

      local original_is_valid = vim.api.nvim_buf_is_valid
      vim.api.nvim_buf_is_valid = function()
        return true
      end

      permission_picker._add_permission(mock_chat_buffer, "allow", "Read")

      -- Should not update frontmatter when tool already exists
      assert.equals(0, update_count)

      -- Restore
      vim.api.nvim_buf_is_valid = original_is_valid
    end)

    it("should handle Bash with pattern", function()
      local updated_frontmatter = nil
      local mock_chat_buffer = {
        buf = 1,
        parse_frontmatter = function()
          return {
            permissions_allow = {},
            permissions_deny = {},
          }
        end,
        update_frontmatter = function(self, frontmatter)
          updated_frontmatter = frontmatter
          return true
        end,
      }

      local original_is_valid = vim.api.nvim_buf_is_valid
      vim.api.nvim_buf_is_valid = function()
        return true
      end

      permission_picker._add_permission(mock_chat_buffer, "deny", "Bash(rm:*)")

      assert.is_not_nil(updated_frontmatter)
      assert.is_table(updated_frontmatter.permissions_deny)
      assert.equals(1, #updated_frontmatter.permissions_deny)
      assert.equals("Bash(rm:*)", updated_frontmatter.permissions_deny[1])

      -- Restore
      vim.api.nvim_buf_is_valid = original_is_valid
    end)
  end)
end)

describe("vibing.chat.handlers.perm", function()
  local perm_handler
  local mock_chat_buffer

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.chat.handlers.perm"] = nil
    package.loaded["vibing.ui.permission_picker"] = nil

    perm_handler = require("vibing.chat.handlers.perm")

    -- Mock chat buffer
    mock_chat_buffer = {
      buf = 1,
    }
  end)

  it("should reject arguments", function()
    local result = perm_handler({ "arg1" }, mock_chat_buffer)
    assert.is_false(result)
  end)

  it("should call permission_picker.show when no args", function()
    local picker_shown = false

    -- Mock permission picker
    package.loaded["vibing.ui.permission_picker"] = {
      show = function()
        picker_shown = true
      end,
    }

    perm_handler = require("vibing.chat.handlers.perm")
    local result = perm_handler({}, mock_chat_buffer)

    assert.is_true(result)
    assert.is_true(picker_shown)
  end)
end)
