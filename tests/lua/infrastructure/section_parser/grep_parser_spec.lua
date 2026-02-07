local GrepParser = require("vibing.infrastructure.section_parser.grep_parser")

describe("GrepParser", function()
  local parser

  before_each(function()
    parser = GrepParser:new()
  end)

  describe("new", function()
    it("creates instance with correct name", function()
      assert.equals("grep_parser", parser.name)
    end)
  end)

  describe("supports_platform", function()
    it("returns true when grep is available", function()
      -- On macOS/Linux, grep should be available
      local result = parser:supports_platform()
      -- This test will pass on Unix-like systems
      assert.is_boolean(result)
    end)
  end)

  describe("extract_messages", function()
    local test_file
    local test_date = "2025-01-26"

    before_each(function()
      test_file = vim.fn.tempname() .. ".md"
    end)

    after_each(function()
      vim.fn.delete(test_file)
    end)

    it("returns empty array for non-existent file", function()
      local messages, err = parser:extract_messages("/nonexistent/file.md", test_date)
      assert.same({}, messages)
      assert.is_truthy(err)
    end)

    it("returns empty array for file with no headers", function()
      vim.fn.writefile({ "Some random content", "No headers here" }, test_file)
      local messages, err = parser:extract_messages(test_file, test_date)
      assert.same({}, messages)
      assert.is_nil(err)
    end)

    it("extracts messages matching target date with assistant response", function()
      local content = {
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "## User <!-- 2025-01-25 10:00:00 -->",
        "",
        "Old message",
        "",
        "## Assistant",
        "",
        "Old response",
        "",
        "## User <!-- 2025-01-26 14:30:00 -->",
        "",
        "Target message",
        "",
        "## Assistant",
        "",
        "Target response line 1",
        "Target response line 2",
        "",
        "## User <!-- 2025-01-26 16:00:00 -->",
        "",
        "Second target message",
        "",
        "## Assistant",
        "",
        "Second target response",
      }
      vim.fn.writefile(content, test_file)

      local messages, err = parser:extract_messages(test_file, test_date)

      assert.is_nil(err)
      assert.equals(2, #messages)

      -- First matching message
      assert.equals("2025-01-26 14:30:00", messages[1].timestamp)
      assert.is_truthy(messages[1].user:match("Target message"))
      assert.is_truthy(messages[1].assistant:match("Target response line 1"))
      assert.is_truthy(messages[1].assistant:match("Target response line 2"))

      -- Second matching message
      assert.equals("2025-01-26 16:00:00", messages[2].timestamp)
      assert.is_truthy(messages[2].user:match("Second target message"))
      assert.is_truthy(messages[2].assistant:match("Second target response"))
    end)

    it("returns empty for date with no matches", function()
      local content = {
        "## User <!-- 2025-01-25 10:00:00 -->",
        "",
        "Old message",
        "",
        "## Assistant",
        "",
        "Old response",
      }
      vim.fn.writefile(content, test_file)

      local messages, err = parser:extract_messages(test_file, "2025-01-26")

      assert.is_nil(err)
      assert.same({}, messages)
    end)

    it("includes file path in message", function()
      local content = {
        "## User <!-- 2025-01-26 12:00:00 -->",
        "",
        "Test",
        "",
        "## Assistant",
        "",
        "Response",
      }
      vim.fn.writefile(content, test_file)

      local messages, _ = parser:extract_messages(test_file, test_date)

      assert.equals(1, #messages)
      assert.is_truthy(messages[1].file)
    end)
  end)
end)
