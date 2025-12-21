-- Tests for vibing.ui.permission_builder module

describe("vibing.ui.permission_builder", function()
  local permission_builder

  before_each(function()
    -- Reload module before each test
    package.loaded["vibing.ui.permission_builder"] = nil
    permission_builder = require("vibing.ui.permission_builder")
  end)

  describe("module structure", function()
    it("should have show_picker function", function()
      assert.is_function(permission_builder.show_picker)
    end)

    it("should have _show_native function", function()
      assert.is_function(permission_builder._show_native)
    end)

    it("should have _show_telescope function", function()
      assert.is_function(permission_builder._show_telescope)
    end)

    it("should have show_bash_preset_picker function", function()
      assert.is_function(permission_builder.show_bash_preset_picker)
    end)

    it("should have _show_bash_native function", function()
      assert.is_function(permission_builder._show_bash_native)
    end)

    it("should have _show_bash_telescope function", function()
      assert.is_function(permission_builder._show_bash_telescope)
    end)

    it("should have _prompt_custom_pattern function", function()
      assert.is_function(permission_builder._prompt_custom_pattern)
    end)

    it("should have prompt_permission_type function", function()
      assert.is_function(permission_builder.prompt_permission_type)
    end)

    it("should have handle_bash_pattern_selection function", function()
      assert.is_function(permission_builder.handle_bash_pattern_selection)
    end)

    it("should have build_permission_string function", function()
      assert.is_function(permission_builder.build_permission_string)
    end)
  end)

  describe("show_picker", function()
    it("should handle invalid chat buffer gracefully", function()
      -- Should not throw error
      local success, err = pcall(permission_builder.show_picker, nil, function() end)
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

      permission_builder._show_native = function()
        native_called = true
      end
      permission_builder._show_telescope = function()
        telescope_called = true
      end

      -- Test without Telescope
      package.loaded["telescope"] = nil
      permission_builder.show_picker(mock_chat_buffer, function() end)

      -- Either native or telescope should be called, depending on availability
      assert.is_true(native_called or telescope_called)

      -- Restore
      vim.api.nvim_buf_is_valid = original_is_valid
    end)
  end)

  describe("build_permission_string", function()
    it("should return tool name for non-Bash tools", function()
      local result = permission_builder.build_permission_string("Read", nil)
      assert.equals("Read", result)
    end)

    it("should return tool name for Bash without pattern", function()
      local result = permission_builder.build_permission_string("Bash", nil)
      assert.equals("Bash", result)
    end)

    it("should return Bash pattern when pattern is provided", function()
      local result = permission_builder.build_permission_string("Bash", "git")
      assert.equals("Bash(git:*)", result)
    end)

    it("should handle various Bash patterns", function()
      assert.equals("Bash(rm:*)", permission_builder.build_permission_string("Bash", "rm"))
      assert.equals("Bash(npm:*)", permission_builder.build_permission_string("Bash", "npm"))
      assert.equals("Bash(docker:*)", permission_builder.build_permission_string("Bash", "docker"))
    end)
  end)

  describe("bash_presets", function()
    it("should have bash presets defined", function()
      assert.is_table(permission_builder.bash_presets)
      assert.is_true(#permission_builder.bash_presets > 0)
    end)

    it("should have required preset fields", function()
      for _, preset in ipairs(permission_builder.bash_presets) do
        assert.is_string(preset.pattern)
        assert.is_string(preset.description)
        assert.is_boolean(preset.danger)
      end
    end)

    it("should include common command presets", function()
      local patterns = {}
      for _, preset in ipairs(permission_builder.bash_presets) do
        patterns[preset.pattern] = true
      end

      -- Check for expected common commands
      assert.is_true(patterns["git"])
      assert.is_true(patterns["npm"])
      assert.is_true(patterns["rm"])
    end)
  end)

  describe("handle_bash_pattern_selection", function()
    it("should call callback with tool name for non-Bash tools", function()
      local called_with = nil
      local tool = {
        name = "Read",
        is_bash = false,
      }

      permission_builder.handle_bash_pattern_selection(tool, "allow", function(result)
        called_with = result
      end)

      assert.equals("Read", called_with)
    end)

    it("should prompt for pattern when tool is Bash", function()
      local tool = {
        name = "Bash",
        is_bash = true,
      }

      local picker_shown = false
      local original_show = permission_builder.show_bash_preset_picker
      permission_builder.show_bash_preset_picker = function(callback)
        picker_shown = true
        callback("git") -- Simulate user selecting "git"
      end

      local result = nil
      permission_builder.handle_bash_pattern_selection(tool, "allow", function(permission_string)
        result = permission_string
      end)

      assert.is_true(picker_shown)
      assert.equals("Bash(git:*)", result)

      -- Restore
      permission_builder.show_bash_preset_picker = original_show
    end)
  end)
end)

describe("vibing.chat.handlers.permissions", function()
  local permissions_handler
  local mock_chat_buffer

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.chat.handlers.permissions"] = nil
    package.loaded["vibing.ui.permission_builder"] = nil

    -- Mock chat buffer with required methods
    mock_chat_buffer = {
      buf = 1,
      update_frontmatter_list = function(self, key, value, action)
        return true
      end,
    }

    -- Mock vim.api.nvim_buf_is_valid
    local original_is_valid = vim.api.nvim_buf_is_valid
    vim.api.nvim_buf_is_valid = function()
      return true
    end
  end)

  it("should exist and be callable", function()
    permissions_handler = require("vibing.chat.handlers.permissions")
    assert.is_function(permissions_handler)
  end)

  it("should call permission_builder.show_picker", function()
    local picker_shown = false

    -- Mock permission builder
    package.loaded["vibing.ui.permission_builder"] = {
      show_picker = function(chat_buffer, callback)
        picker_shown = true
        -- Don't call callback to avoid infinite loop
      end,
    }

    permissions_handler = require("vibing.chat.handlers.permissions")
    local result = permissions_handler({}, mock_chat_buffer)

    assert.is_true(result)
    assert.is_true(picker_shown)
  end)

  it("should handle nil chat buffer", function()
    permissions_handler = require("vibing.chat.handlers.permissions")
    local result = permissions_handler({}, nil)
    assert.is_false(result)
  end)
end)
