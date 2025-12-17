-- Tests for vibing.ui.output_buffer module

describe("vibing.ui.output_buffer", function()
  local OutputBuffer

  before_each(function()
    package.loaded["vibing.ui.output_buffer"] = nil
    OutputBuffer = require("vibing.ui.output_buffer")
  end)

  describe("new", function()
    it("should create output buffer instance", function()
      local output = OutputBuffer:new()
      assert.is_not_nil(output)
      assert.is_nil(output.buf)
      assert.is_nil(output.win)
    end)
  end)

  describe("open", function()
    it("should create buffer and window", function()
      local output = OutputBuffer:new()
      output:open("Test Output 1")

      assert.is_not_nil(output.buf)
      assert.is_true(vim.api.nvim_buf_is_valid(output.buf))
      assert.is_not_nil(output.win)
      assert.is_true(vim.api.nvim_win_is_valid(output.win))

      output:close()
    end)

    it("should set buffer properties correctly", function()
      local output = OutputBuffer:new()
      output:open("Test Props")

      assert.equals("markdown", vim.bo[output.buf].filetype)
      assert.equals("nofile", vim.bo[output.buf].buftype)
      assert.is_false(vim.bo[output.buf].swapfile)

      output:close()
    end)

    it("should set initial content with title", function()
      local output = OutputBuffer:new()
      output:open("My Title")

      local lines = vim.api.nvim_buf_get_lines(output.buf, 0, -1, false)
      assert.equals("# My Title", lines[1])
      assert.equals("", lines[2])
      assert.equals("Loading...", lines[3])

      output:close()
    end)

    it("should set buffer name with vibing:// prefix", function()
      local output = OutputBuffer:new()
      output:open("TestName Unique")

      local name = vim.api.nvim_buf_get_name(output.buf)
      assert.is_not_nil(name:match("vibing://"))

      output:close()
    end)
  end)

  describe("close", function()
    it("should close window when open", function()
      local output = OutputBuffer:new()
      output:open("Close Test 1")
      local win = output.win

      output:close()

      assert.is_false(vim.api.nvim_win_is_valid(win))
      assert.is_nil(output.win)
    end)

    it("should handle closing when already closed", function()
      local output = OutputBuffer:new()
      assert.has_no.errors(function()
        output:close()
      end)
    end)

    it("should handle closing invalid window", function()
      local output = OutputBuffer:new()
      output.win = 999999

      assert.has_no.errors(function()
        output:close()
      end)
    end)
  end)

  describe("is_open", function()
    it("should return false when not opened", function()
      local output = OutputBuffer:new()
      assert.is_false(output:is_open())
    end)

    it("should return true when open", function()
      local output = OutputBuffer:new()
      output:open("Test " .. os.time())

      assert.is_true(output:is_open())

      output:close()
    end)

    it("should return false after closing", function()
      local output = OutputBuffer:new()
      output:open("Test " .. os.time())
      output:close()

      assert.is_false(output:is_open())
    end)
  end)

  describe("set_content", function()
    it("should replace content in buffer", function()
      local output = OutputBuffer:new()
      output:open("Test " .. os.time())

      output:set_content("New content\nMultiple lines")

      local lines = vim.api.nvim_buf_get_lines(output.buf, 0, -1, false)
      -- Line 1-2: title and blank, Line 3+: content
      assert.equals("# Test", lines[1])
      assert.equals("", lines[2])
      assert.equals("New content", lines[3])
      assert.equals("Multiple lines", lines[4])

      output:close()
    end)

    it("should handle empty content", function()
      local output = OutputBuffer:new()
      output:open("Test " .. os.time())

      output:set_content("")

      local lines = vim.api.nvim_buf_get_lines(output.buf, 0, -1, false)
      assert.equals(3, #lines) -- Title, blank, empty content line

      output:close()
    end)

    it("should handle invalid buffer gracefully", function()
      local output = OutputBuffer:new()
      output.buf = 999999

      assert.has_no.errors(function()
        output:set_content("Test")
      end)
    end)
  end)

  describe("append_chunk", function()
    it("should append chunk to last line", function()
      local output = OutputBuffer:new()
      output:open("Test " .. os.time())

      output:append_chunk("First chunk", true)
      output:append_chunk(" second chunk", false)

      local lines = vim.api.nvim_buf_get_lines(output.buf, 0, -1, false)
      -- Should append to same line
      local last_line = lines[#lines]
      assert.is_not_nil(last_line:match("First chunk second chunk"))

      output:close()
    end)

    it("should remove 'Loading...' on first chunk", function()
      local output = OutputBuffer:new()
      output:open("Test " .. os.time())

      output:append_chunk("Content", true)

      local lines = vim.api.nvim_buf_get_lines(output.buf, 0, -1, false)
      local has_loading = false
      for _, line in ipairs(lines) do
        if line:match("Loading%.%.%.") then
          has_loading = true
        end
      end
      assert.is_false(has_loading)

      output:close()
    end)

    it("should handle multiline chunks", function()
      local output = OutputBuffer:new()
      output:open("Test " .. os.time())

      output:append_chunk("Line 1\nLine 2\nLine 3", true)

      local lines = vim.api.nvim_buf_get_lines(output.buf, 0, -1, false)
      assert.is_not_nil(lines[3]:match("Line 1"))
      assert.is_not_nil(lines[4]:match("Line 2"))
      assert.is_not_nil(lines[5]:match("Line 3"))

      output:close()
    end)

    it("should handle invalid buffer gracefully", function()
      local output = OutputBuffer:new()
      output.buf = 999999

      assert.has_no.errors(function()
        output:append_chunk("Test", true)
      end)
    end)
  end)

  describe("show_error", function()
    it("should display error message", function()
      local output = OutputBuffer:new()
      output:open("Test " .. os.time())

      output:show_error("Something went wrong")

      local lines = vim.api.nvim_buf_get_lines(output.buf, 0, -1, false)
      local has_error_header = false
      local has_error_msg = false
      for _, line in ipairs(lines) do
        if line:match("**Error:**") then
          has_error_header = true
        end
        if line:match("Something went wrong") then
          has_error_msg = true
        end
      end

      assert.is_true(has_error_header)
      assert.is_true(has_error_msg)

      output:close()
    end)

    it("should replace existing content with error", function()
      local output = OutputBuffer:new()
      output:open("Test " .. os.time())
      output:set_content("Previous content")

      output:show_error("Error occurred")

      local lines = vim.api.nvim_buf_get_lines(output.buf, 0, -1, false)
      local has_previous = false
      for _, line in ipairs(lines) do
        if line:match("Previous content") then
          has_previous = true
        end
      end
      assert.is_false(has_previous)

      output:close()
    end)

    it("should handle invalid buffer gracefully", function()
      local output = OutputBuffer:new()
      output.buf = 999999

      assert.has_no.errors(function()
        output:show_error("Error")
      end)
    end)
  end)

  describe("integration", function()
    it("should handle full lifecycle", function()
      local output = OutputBuffer:new()

      -- Open
      output:open("Integration Test")
      assert.is_true(output:is_open())

      -- Stream content
      output:append_chunk("Hello", true)
      output:append_chunk(" World", false)

      -- Set full content
      output:set_content("Complete message")

      -- Close
      output:close()
      assert.is_false(output:is_open())
    end)

    it("should handle error scenario", function()
      local output = OutputBuffer:new()
      output:open("Error Test")

      output:append_chunk("Starting...", true)
      output:show_error("Connection failed")

      assert.is_true(output:is_open())
      output:close()
    end)
  end)
end)
