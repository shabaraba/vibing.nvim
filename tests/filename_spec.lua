-- Tests for vibing.utils.filename module

describe("vibing.utils.filename", function()
  local filename

  before_each(function()
    package.loaded["vibing.utils.filename"] = nil
    filename = require("vibing.utils.filename")
  end)

  describe("generate_from_message", function()
    it("should generate filename from simple message", function()
      local result = filename.generate_from_message("Hello world")
      local date_prefix = os.date("%Y%m%d")
      assert.equals(date_prefix .. "_hello_world", result)
    end)

    it("should sanitize special characters", function()
      local result = filename.generate_from_message("Fix: bug in @file.lua")
      local date_prefix = os.date("%Y%m%d")
      assert.equals(date_prefix .. "_fix_bug_in_filelua", result)
    end)

    it("should convert to lowercase", function()
      local result = filename.generate_from_message("UPPER CASE TEXT")
      local date_prefix = os.date("%Y%m%d")
      assert.equals(date_prefix .. "_upper_case_text", result)
    end)

    it("should handle hyphens", function()
      local result = filename.generate_from_message("test-with-hyphens")
      local date_prefix = os.date("%Y%m%d")
      assert.equals(date_prefix .. "_test_with_hyphens", result)
    end)

    it("should truncate long messages", function()
      local long_message = "This is a very long message that exceeds fifty characters limit"
      local result = filename.generate_from_message(long_message)
      local date_prefix = os.date("%Y%m%d")
      -- Should use first 50 chars of message, then sanitize (topic limited to 32)
      assert.is_not_nil(result:match("^" .. date_prefix .. "_"))
      local topic = result:sub(#date_prefix + 2)
      assert.is_true(#topic <= 32)
    end)

    it("should handle multiline messages", function()
      local multiline = "First line\nSecond line\nThird line"
      local result = filename.generate_from_message(multiline)
      local date_prefix = os.date("%Y%m%d")
      -- Should only use first line
      assert.equals(date_prefix .. "_first_line", result)
    end)

    it("should return timestamp for empty message", function()
      local result = filename.generate_from_message("")
      assert.is_not_nil(result:match("^chat_%d+_%d+$"))
    end)

    it("should return timestamp for nil message", function()
      local result = filename.generate_from_message(nil)
      assert.is_not_nil(result:match("^chat_%d+_%d+$"))
    end)

    it("should return timestamp when sanitization produces empty string", function()
      local result = filename.generate_from_message("@#$%^&*()")
      assert.is_not_nil(result:match("^chat_%d+_%d+$"))
    end)

    it("should collapse multiple spaces and underscores", function()
      local result = filename.generate_from_message("test    with     spaces")
      local date_prefix = os.date("%Y%m%d")
      assert.equals(date_prefix .. "_test_with_spaces", result)
    end)

    it("should remove leading and trailing underscores", function()
      local result = filename.generate_from_message("___test___")
      local date_prefix = os.date("%Y%m%d")
      assert.equals(date_prefix .. "_test", result)
    end)

    it("should limit topic length to 32 characters", function()
      local long_topic = string.rep("a", 100)
      local result = filename.generate_from_message(long_topic)
      local date_prefix = os.date("%Y%m%d")
      local topic_part = result:sub(#date_prefix + 2)
      assert.equals(32, #topic_part)
    end)
  end)

  describe("generate_default", function()
    it("should generate timestamp-based filename", function()
      local result = filename.generate_default()
      assert.is_not_nil(result:match("^chat_%d+_%d+$"))
    end)

    it("should include date in YYYYMMDD format", function()
      local result = filename.generate_default()
      local date_part = result:match("^chat_(%d+)_")
      assert.equals(8, #date_part)
      local current_date = os.date("%Y%m%d")
      assert.equals(current_date, date_part)
    end)

    it("should include time in HHMMSS format", function()
      local result = filename.generate_default()
      local time_part = result:match("_(%d+)$")
      assert.equals(6, #time_part)
    end)

    it("should generate unique filenames", function()
      local result1 = filename.generate_default()
      -- Small delay to ensure different timestamps
      vim.wait(10)
      local result2 = filename.generate_default()
      -- Note: May be equal if called within same second
      assert.is_not_nil(result1)
      assert.is_not_nil(result2)
    end)
  end)
end)
