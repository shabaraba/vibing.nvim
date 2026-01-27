local LineParser = require("vibing.infrastructure.section_parser.line_parser")

describe("LineParser", function()
  local parser

  before_each(function()
    parser = LineParser:new()
  end)

  describe("new", function()
    it("creates instance with correct name", function()
      assert.equals("line_parser", parser.name)
    end)
  end)

  describe("supports_platform", function()
    it("always returns true", function()
      assert.is_true(parser:supports_platform())
    end)
  end)

  describe("extract_messages", function()
    local test_file
    local test_date = "2025-01-26"

    before_each(function()
      test_file = vim.fn.tempname() .. ".vibing"
    end)

    after_each(function()
      vim.fn.delete(test_file)
    end)

    it("returns empty array for non-existent file", function()
      local messages, err = parser:extract_messages("/nonexistent/file.vibing", test_date)
      assert.same({}, messages)
      assert.is_truthy(err)
    end)

    it("extracts messages matching target date", function()
      local content = {
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
        "Target response",
      }
      vim.fn.writefile(content, test_file)

      local messages, err = parser:extract_messages(test_file, test_date)

      assert.is_nil(err)
      assert.equals(1, #messages)
      assert.equals("2025-01-26 14:30:00", messages[1].timestamp)
      assert.is_truthy(messages[1].user:match("Target message"))
      assert.is_truthy(messages[1].assistant:match("Target response"))
    end)
  end)
end)
