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

  describe("open and close", function()
    it("should create buffer and window", function()
      local output = OutputBuffer:new()
      local timestamp = os.time()
      output:open("Test " .. timestamp)

      assert.is_not_nil(output.buf)
      assert.is_true(vim.api.nvim_buf_is_valid(output.buf))
      assert.is_not_nil(output.win)
      assert.is_true(vim.api.nvim_win_is_valid(output.win))

      output:close()
    end)

    it("should set buffer properties correctly", function()
      local output = OutputBuffer:new()
      output:open("Props Test " .. os.time())

      assert.equals("markdown", vim.bo[output.buf].filetype)
      assert.equals("nofile", vim.bo[output.buf].buftype)
      assert.is_false(vim.bo[output.buf].swapfile)

      output:close()
    end)

    it("should close window when open", function()
      local output = OutputBuffer:new()
      output:open("Close Test " .. os.time())
      local win = output.win

      output:close()

      assert.is_false(vim.api.nvim_win_is_valid(win))
      assert.is_nil(output.win)
    end)
  end)

  describe("is_open", function()
    it("should return false when not opened", function()
      local output = OutputBuffer:new()
      assert.is_false(output:is_open())
    end)

    it("should return true when open", function()
      local output = OutputBuffer:new()
      output:open("Open Check " .. os.time())

      assert.is_true(output:is_open())

      output:close()
    end)

    it("should return false after closing", function()
      local output = OutputBuffer:new()
      output:open("Close Check " .. os.time())
      output:close()

      assert.is_false(output:is_open())
    end)
  end)

  describe("set_content", function()
    it("should replace content in buffer", function()
      local output = OutputBuffer:new()
      output:open("Content Test " .. os.time())

      output:set_content("New content\nMultiple lines")

      local lines = vim.api.nvim_buf_get_lines(output.buf, 0, -1, false)
      -- Check that content was set
      local found_content = false
      for _, line in ipairs(lines) do
        if line:match("New content") then
          found_content = true
        end
      end
      assert.is_true(found_content)

      output:close()
    end)
  end)

  describe("append_chunk", function()
    it("should append chunk to buffer", function()
      local output = OutputBuffer:new()
      output:open("Chunk Test " .. os.time())

      output:append_chunk("First chunk", true)
      output:append_chunk(" second", false)

      local lines = vim.api.nvim_buf_get_lines(output.buf, 0, -1, false)
      local has_content = false
      for _, line in ipairs(lines) do
        if line:match("First chunk") then
          has_content = true
        end
      end
      assert.is_true(has_content)

      output:close()
    end)
  end)

  describe("show_error", function()
    it("should display error message", function()
      local output = OutputBuffer:new()
      output:open("Error Test " .. os.time())

      output:show_error("Something went wrong")

      local lines = vim.api.nvim_buf_get_lines(output.buf, 0, -1, false)
      local has_error = false
      for _, line in ipairs(lines) do
        if line:match("Error") or line:match("wrong") then
          has_error = true
        end
      end

      assert.is_true(has_error)

      output:close()
    end)
  end)

  describe("integration", function()
    it("should handle full lifecycle", function()
      local output = OutputBuffer:new()

      -- Open
      output:open("Lifecycle " .. os.time())
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
  end)
end)
