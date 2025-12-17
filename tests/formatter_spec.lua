-- Tests for vibing.context.formatter module

describe("vibing.context.formatter", function()
  local formatter

  before_each(function()
    package.loaded["vibing.context.formatter"] = nil
    formatter = require("vibing.context.formatter")
  end)

  describe("format_prompt", function()
    it("should return prompt unchanged when no contexts", function()
      local prompt = "Hello, Claude!"
      local result = formatter.format_prompt(prompt, {}, "append")
      assert.equals(prompt, result)
    end)

    it("should return prompt unchanged when contexts is nil", function()
      local prompt = "Hello, Claude!"
      local result = formatter.format_prompt(prompt, nil, "append")
      assert.equals(prompt, result)
    end)

    it("should append contexts when position is append", function()
      local prompt = "Explain this code"
      local contexts = { "@file:src/main.lua", "@file:src/config.lua" }
      local result = formatter.format_prompt(prompt, contexts, "append")

      assert.is_not_nil(result:match("^Explain this code\n\n"))
      assert.is_not_nil(result:match("# Context Files"))
      assert.is_not_nil(result:match("@file:src/main%.lua"))
      assert.is_not_nil(result:match("@file:src/config%.lua"))
    end)

    it("should prepend contexts when position is prepend", function()
      local prompt = "Explain this code"
      local contexts = { "@file:src/main.lua" }
      local result = formatter.format_prompt(prompt, contexts, "prepend")

      assert.is_not_nil(result:match("^# Context Files"))
      assert.is_not_nil(result:match("Explain this code$"))
    end)

    it("should default to prepend when position is invalid", function()
      local prompt = "Test prompt"
      local contexts = { "@file:test.lua" }
      local result = formatter.format_prompt(prompt, contexts, "invalid")

      -- Should prepend by default
      assert.is_not_nil(result:match("^# Context Files"))
    end)

    it("should handle multiple contexts", function()
      local prompt = "Review these files"
      local contexts = {
        "@file:src/a.lua",
        "@file:src/b.lua",
        "@file:src/c.lua",
      }
      local result = formatter.format_prompt(prompt, contexts, "append")

      for _, ctx in ipairs(contexts) do
        local escaped = ctx:gsub("%.", "%%."):gsub("%-", "%%-")
        assert.is_not_nil(result:match(escaped))
      end
    end)
  end)

  describe("format_contexts_section", function()
    it("should return empty string for empty contexts", function()
      local result = formatter.format_contexts_section({})
      assert.equals("", result)
    end)

    it("should return empty string for nil contexts", function()
      local result = formatter.format_contexts_section(nil)
      assert.equals("", result)
    end)

    it("should format single context", function()
      local contexts = { "@file:src/main.lua" }
      local result = formatter.format_contexts_section(contexts)

      assert.equals("# Context Files\n@file:src/main.lua", result)
    end)

    it("should format multiple contexts with header", function()
      local contexts = {
        "@file:src/main.lua",
        "@file:src/config.lua",
        "@file:src/utils.lua",
      }
      local result = formatter.format_contexts_section(contexts)

      assert.is_not_nil(result:match("^# Context Files\n"))
      assert.is_not_nil(result:match("@file:src/main%.lua"))
      assert.is_not_nil(result:match("@file:src/config%.lua"))
      assert.is_not_nil(result:match("@file:src/utils%.lua"))
    end)

    it("should separate contexts with newlines", function()
      local contexts = { "@file:a.lua", "@file:b.lua" }
      local result = formatter.format_contexts_section(contexts)

      local lines = vim.split(result, "\n", { plain = true })
      assert.equals(3, #lines) -- Header + 2 contexts
    end)

    it("should preserve exact context format", function()
      local contexts = {
        "@file:path/to/file.lua",
        "@file:path/to/file.lua:L10-L20",
      }
      local result = formatter.format_contexts_section(contexts)

      assert.is_not_nil(result:match("@file:path/to/file%.lua\n"))
      assert.is_not_nil(result:match("@file:path/to/file%.lua:L10%-L20"))
    end)
  end)

  describe("format_for_display", function()
    it("should return 'No context' for empty contexts", function()
      local result = formatter.format_for_display({})
      assert.equals("No context", result)
    end)

    it("should return 'No context' for nil contexts", function()
      local result = formatter.format_for_display(nil)
      assert.equals("No context", result)
    end)

    it("should format single context", function()
      local contexts = { "@file:src/main.lua" }
      local result = formatter.format_for_display(contexts)
      assert.equals("@file:src/main.lua", result)
    end)

    it("should join multiple contexts with commas", function()
      local contexts = {
        "@file:src/main.lua",
        "@file:src/config.lua",
      }
      local result = formatter.format_for_display(contexts)
      assert.equals("@file:src/main.lua, @file:src/config.lua", result)
    end)

    it("should handle many contexts", function()
      local contexts = {
        "@file:a.lua",
        "@file:b.lua",
        "@file:c.lua",
        "@file:d.lua",
      }
      local result = formatter.format_for_display(contexts)
      assert.equals("@file:a.lua, @file:b.lua, @file:c.lua, @file:d.lua", result)
    end)

    it("should preserve special characters in paths", function()
      local contexts = {
        "@file:path-with-hyphens/file_with_underscores.lua",
        "@file:path/with/dots.test.lua",
      }
      local result = formatter.format_for_display(contexts)
      assert.is_not_nil(result:match("path%-with%-hyphens"))
      assert.is_not_nil(result:match("file_with_underscores"))
    end)
  end)
end)
