-- Tests for vibing.completion module

describe("vibing.completion", function()
  local completion
  local commands

  before_each(function()
    -- Reload modules before each test
    package.loaded["vibing.completion"] = nil
    package.loaded["vibing.chat.commands"] = nil
    completion = require("vibing.completion")
    commands = require("vibing.chat.commands")

    -- Clear registered commands
    commands.commands = {}
    commands.custom_commands = {}

    -- Register test commands
    commands.register({
      name = "context",
      handler = function() end,
      description = "Add file to context",
    })
    commands.register({
      name = "clear",
      handler = function() end,
      description = "Clear context",
    })
    commands.register({
      name = "mode",
      handler = function() end,
      description = "Set mode",
    })
    commands.register_custom({
      name = "custom1",
      content = "Custom command 1",
      description = "Test custom command",
      source = "custom",
    })
  end)

  describe("slash_command_complete", function()
    -- Mock vim.api functions
    local original_get_current_line
    local original_win_get_cursor

    before_each(function()
      original_get_current_line = vim.api.nvim_get_current_line
      original_win_get_cursor = vim.api.nvim_win_get_cursor
    end)

    after_each(function()
      vim.api.nvim_get_current_line = original_get_current_line
      vim.api.nvim_win_get_cursor = original_win_get_cursor
    end)

    describe("findstart mode (findstart=1)", function()
      it("should return completion start position after /", function()
        vim.api.nvim_get_current_line = function()
          return "/context"
        end
        vim.api.nvim_win_get_cursor = function()
          return { 1, 8 } -- cursor at end of "context"
        end

        local result = completion.slash_command_complete(1, "")
        assert.equals(1, result) -- 0-indexed position after /
      end)

      it("should handle / at beginning of line", function()
        vim.api.nvim_get_current_line = function()
          return "/c"
        end
        vim.api.nvim_win_get_cursor = function()
          return { 1, 2 }
        end

        local result = completion.slash_command_complete(1, "")
        assert.equals(1, result)
      end)

      it("should return -1 when no / found", function()
        vim.api.nvim_get_current_line = function()
          return "no slash here"
        end
        vim.api.nvim_win_get_cursor = function()
          return { 1, 5 }
        end

        local result = completion.slash_command_complete(1, "")
        assert.equals(-1, result)
      end)

      it("should handle / in middle of line", function()
        vim.api.nvim_get_current_line = function()
          return "some text /context"
        end
        vim.api.nvim_win_get_cursor = function()
          return { 1, 18 }
        end

        local result = completion.slash_command_complete(1, "")
        assert.equals(11, result) -- position after /
      end)
    end)

    describe("completion mode (findstart=0)", function()
      it("should return all commands with empty base", function()
        local result = completion.slash_command_complete(0, "")

        assert.is_table(result)
        assert.equals(4, #result) -- context, clear, mode, custom1

        -- Check if all commands are present
        local names = {}
        for _, item in ipairs(result) do
          names[item.word] = true
        end
        assert.is_true(names["context"])
        assert.is_true(names["clear"])
        assert.is_true(names["mode"])
        assert.is_true(names["custom1"])
      end)

      it("should filter commands by prefix", function()
        local result = completion.slash_command_complete(0, "c")

        assert.is_table(result)
        -- Should include: clear, context, custom1
        assert.equals(3, #result)

        local names = {}
        for _, item in ipairs(result) do
          names[item.word] = true
        end
        assert.is_true(names["context"])
        assert.is_true(names["clear"])
        assert.is_true(names["custom1"])
        assert.is_nil(names["mode"])
      end)

      it("should filter commands exactly matching prefix", function()
        local result = completion.slash_command_complete(0, "cont")

        assert.is_table(result)
        assert.equals(1, #result)
        assert.equals("context", result[1].word)
      end)

      it("should return empty table when no match", function()
        local result = completion.slash_command_complete(0, "xyz")

        assert.is_table(result)
        assert.equals(0, #result)
      end)

      it("should include / in abbr field", function()
        local result = completion.slash_command_complete(0, "")

        for _, item in ipairs(result) do
          assert.is_string(item.abbr)
          assert.is_not_nil(item.abbr:match("^/"))
        end
      end)

      it("should set kind to B for builtin commands", function()
        local result = completion.slash_command_complete(0, "context")

        assert.equals(1, #result)
        assert.equals("B", result[1].kind)
      end)

      it("should set kind to C for custom commands", function()
        local result = completion.slash_command_complete(0, "custom")

        assert.equals(1, #result)
        assert.equals("C", result[1].kind)
      end)

      it("should include description in menu field", function()
        local result = completion.slash_command_complete(0, "context")

        assert.equals(1, #result)
        assert.equals("Add file to context", result[1].menu)
      end)

      it("should sort results by name", function()
        local result = completion.slash_command_complete(0, "")

        -- Check if sorted alphabetically
        for i = 2, #result do
          assert.is_true(result[i-1].word < result[i].word)
        end
      end)

      it("should handle commands with empty description", function()
        commands.register({
          name = "nodesc",
          handler = function() end,
          description = nil,
        })

        local result = completion.slash_command_complete(0, "nodesc")

        assert.equals(1, #result)
        assert.equals("", result[1].menu)
      end)
    end)
  end)
end)
