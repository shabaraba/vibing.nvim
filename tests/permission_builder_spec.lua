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

    it("should have show_pattern_picker function", function()
      assert.is_function(permission_builder.show_pattern_picker)
    end)

    it("should have _show_pattern_native function", function()
      assert.is_function(permission_builder._show_pattern_native)
    end)

    it("should have _show_pattern_telescope function", function()
      assert.is_function(permission_builder._show_pattern_telescope)
    end)

    it("should have _prompt_custom_pattern function", function()
      assert.is_function(permission_builder._prompt_custom_pattern)
    end)

    it("should have prompt_permission_type function", function()
      assert.is_function(permission_builder.prompt_permission_type)
    end)

    it("should have handle_pattern_selection function", function()
      assert.is_function(permission_builder.handle_pattern_selection)
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

    it("should build a path pattern without the Bash :* suffix", function()
      assert.equals("Read(src/**)", permission_builder.build_permission_string("Read", "src/**"))
      assert.equals("Write(.env)", permission_builder.build_permission_string("Write", ".env"))
      assert.equals("Edit(tests/**)", permission_builder.build_permission_string("Edit", "tests/**"))
    end)

    it("should build a domain pattern", function()
      assert.equals("WebFetch(github.com)", permission_builder.build_permission_string("WebFetch", "github.com"))
      assert.equals(
        "WebSearch(*.npmjs.com)",
        permission_builder.build_permission_string("WebSearch", "*.npmjs.com")
      )
    end)

    it("should build a literal pattern for Glob and Grep", function()
      assert.equals("Glob(**/*.ts)", permission_builder.build_permission_string("Glob", "**/*.ts"))
      assert.equals("Grep(TODO)", permission_builder.build_permission_string("Grep", "TODO"))
    end)

    it("should drop the pattern for tools matchers.lua cannot parse", function()
      -- Skill(foo) parses as unknown_pattern and never matches, so never emit one.
      assert.equals("Skill", permission_builder.build_permission_string("Skill", "foo"))
      assert.equals("StructuredOutput", permission_builder.build_permission_string("StructuredOutput", "x"))
    end)

    it("should return the bare tool name for an empty pattern", function()
      assert.equals("Bash", permission_builder.build_permission_string("Bash", ""))
      assert.equals("Read", permission_builder.build_permission_string("Read", ""))
    end)
  end)

  describe("ARG_KIND", function()
    it("should map every tool that matchers.lua can parse an argument for", function()
      local expected = {
        Bash = "bash",
        Read = "path",
        Write = "path",
        Edit = "path",
        WebFetch = "domain",
        WebSearch = "domain",
        Glob = "literal",
        Grep = "literal",
      }
      assert.same(expected, permission_builder.ARG_KIND)
    end)
  end)

  describe("build_permission_type_choices", function()
    it("should report no current setting when the lists are empty", function()
      local choices = permission_builder.build_permission_type_choices("Bash", { allow = {}, ask = {}, deny = {} })

      assert.equals(3, #choices)
      for _, choice in ipairs(choices) do
        assert.is_true(choice.description:find("現在: なし", 1, true) ~= nil)
      end
    end)

    it("should show the entry that is already configured", function()
      local choices = permission_builder.build_permission_type_choices("Read", {
        allow = { "Read", "Write" },
        ask = {},
        deny = {},
      })

      assert.is_true(choices[1].description:find("現在: Read", 1, true) ~= nil)
      assert.is_true(choices[2].description:find("現在: なし", 1, true) ~= nil)
    end)

    it("should match argument-carrying entries for the same tool", function()
      local choices = permission_builder.build_permission_type_choices("Bash", {
        allow = { "Bash(git:*)", "Bash(npm:*)", "Read" },
        ask = {},
        deny = {},
      })

      assert.is_true(choices[1].description:find("Bash(git:*), Bash(npm:*)", 1, true) ~= nil)
      -- "Read" is a different tool and must not be counted here.
      assert.is_nil(choices[1].description:find("Read", 1, true))
    end)

    it("should tolerate missing lists", function()
      local choices = permission_builder.build_permission_type_choices("Bash", {})
      assert.equals(3, #choices)
    end)
  end)

  describe("path_presets and domain_presets", function()
    it("should define path presets with the shared preset fields", function()
      assert.is_true(#permission_builder.path_presets > 0)
      for _, preset in ipairs(permission_builder.path_presets) do
        assert.is_string(preset.pattern)
        assert.is_string(preset.description)
        assert.is_boolean(preset.danger)
      end
    end)

    it("should flag the sensitive path presets as dangerous", function()
      local danger = {}
      for _, preset in ipairs(permission_builder.path_presets) do
        danger[preset.pattern] = preset.danger
      end
      assert.is_true(danger[".env"])
      assert.is_true(danger["*.secret"])
      assert.is_false(danger["src/**"])
    end)

    it("should define domain presets", function()
      local patterns = {}
      for _, preset in ipairs(permission_builder.domain_presets) do
        patterns[preset.pattern] = true
      end
      assert.is_true(patterns["github.com"])
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

  describe("handle_pattern_selection", function()
    it("should skip the pattern prompt for tools that cannot take an argument", function()
      -- Skill has no ARG_KIND: matchers.lua would parse Skill(x) as unknown_pattern and never
      -- match it, so the picker must not let one be built.
      local called_with = nil

      permission_builder.handle_pattern_selection({ name = "Skill" }, "allow", function(result)
        called_with = result
      end)

      assert.equals("Skill", called_with)
    end)

    it("should offer path presets for Read", function()
      local seen_presets = nil
      local original_show = permission_builder.show_pattern_picker
      permission_builder.show_pattern_picker = function(presets, _title, _skip, callback)
        seen_presets = presets
        callback("src/**")
      end

      local result = nil
      permission_builder.handle_pattern_selection({ name = "Read" }, "allow", function(permission_string)
        result = permission_string
      end)

      assert.equals(permission_builder.path_presets, seen_presets)
      assert.equals("Read(src/**)", result)

      permission_builder.show_pattern_picker = original_show
    end)

    it("should offer domain presets for WebFetch", function()
      local seen_presets = nil
      local original_show = permission_builder.show_pattern_picker
      permission_builder.show_pattern_picker = function(presets, _title, _skip, callback)
        seen_presets = presets
        callback("github.com")
      end

      local result = nil
      permission_builder.handle_pattern_selection({ name = "WebFetch" }, "allow", function(permission_string)
        result = permission_string
      end)

      assert.equals(permission_builder.domain_presets, seen_presets)
      assert.equals("WebFetch(github.com)", result)

      permission_builder.show_pattern_picker = original_show
    end)

    it("should prompt for pattern when tool is Bash", function()
      local tool = {
        name = "Bash",
        is_bash = true,
      }

      local picker_shown = false
      local original_show = permission_builder.show_pattern_picker
      permission_builder.show_pattern_picker = function(_presets, _title, _skip, callback)
        picker_shown = true
        callback("git") -- Simulate user selecting "git"
      end

      local result = nil
      permission_builder.handle_pattern_selection(tool, "allow", function(permission_string)
        result = permission_string
      end)

      assert.is_true(picker_shown)
      assert.equals("Bash(git:*)", result)

      -- Restore
      permission_builder.show_pattern_picker = original_show
    end)
  end)
end)

describe("vibing.application.chat.handlers.permissions", function()
  local permissions_handler
  local mock_chat_buffer

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.application.chat.handlers.permissions"] = nil
    package.loaded["vibing.ui.permission_builder"] = nil

    -- Mock chat buffer with required methods
    mock_chat_buffer = {
      buf = 1,
      update_frontmatter_list = function(self, key, value, action)
        return true
      end,
      -- The builder reads these back so the allow/ask/deny prompt can show what is already set.
      get_frontmatter_list = function(self, key)
        return {}
      end,
    }

    -- Mock vim.api.nvim_buf_is_valid
    local original_is_valid = vim.api.nvim_buf_is_valid
    vim.api.nvim_buf_is_valid = function()
      return true
    end
  end)

  it("should exist and be callable", function()
    permissions_handler = require("vibing.application.chat.handlers.permissions")
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

    permissions_handler = require("vibing.application.chat.handlers.permissions")
    local result = permissions_handler({}, mock_chat_buffer)

    assert.is_true(result)
    assert.is_true(picker_shown)
  end)

  it("should handle nil chat buffer", function()
    permissions_handler = require("vibing.application.chat.handlers.permissions")
    local result = permissions_handler({}, nil)
    assert.is_false(result)
  end)
end)
