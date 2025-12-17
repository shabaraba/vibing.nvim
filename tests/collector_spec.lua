-- Tests for vibing.context.collector module

describe("vibing.context.collector", function()
  local collector

  before_each(function()
    package.loaded["vibing.context.collector"] = nil
    collector = require("vibing.context.collector")
  end)

  describe("_to_relative_path", function()
    it("should convert absolute path to relative", function()
      local cwd = vim.fn.getcwd()
      local absolute = cwd .. "/src/main.lua"
      local result = collector._to_relative_path(absolute)
      assert.equals("src/main.lua", result)
    end)

    it("should return original path if not under cwd", function()
      local absolute = "/tmp/some/file.lua"
      local result = collector._to_relative_path(absolute)
      assert.equals(absolute, result)
    end)

    it("should handle cwd root correctly", function()
      local cwd = vim.fn.getcwd()
      local result = collector._to_relative_path(cwd)
      assert.equals(cwd, result)
    end)
  end)

  describe("_is_valid_buffer", function()
    it("should reject invalid buffer", function()
      local result = collector._is_valid_buffer(999999)
      assert.is_false(result)
    end)

    it("should reject special buffer types", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = "nofile"
      local result = collector._is_valid_buffer(buf)
      assert.is_false(result)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("should accept normal file buffer", function()
      local buf = vim.api.nvim_create_buf(true, false)
      local tmpfile = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(buf, tmpfile)
      local result = collector._is_valid_buffer(buf)
      assert.is_true(result)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("should reject .git paths", function()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, "/path/to/.git/config")
      local result = collector._is_valid_buffer(buf)
      assert.is_false(result)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("should reject node_modules paths", function()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, "/path/node_modules/package/index.js")
      local result = collector._is_valid_buffer(buf)
      assert.is_false(result)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("should reject .vibing paths", function()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, "/path/.vibing/chat.md")
      local result = collector._is_valid_buffer(buf)
      assert.is_false(result)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("collect_selection", function()
    it("should create line range mention", function()
      local buf = vim.api.nvim_create_buf(true, false)
      local cwd = vim.fn.getcwd()
      vim.api.nvim_buf_set_name(buf, cwd .. "/test.lua")

      local result = collector.collect_selection(buf, 10, 25)
      assert.equals("@file:test.lua:L10-L25", result)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("should return nil for unnamed buffer", function()
      local buf = vim.api.nvim_create_buf(true, false)
      local result = collector.collect_selection(buf, 1, 5)
      assert.is_nil(result)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("should handle single line selection", function()
      local buf = vim.api.nvim_create_buf(true, false)
      local cwd = vim.fn.getcwd()
      vim.api.nvim_buf_set_name(buf, cwd .. "/single.lua")

      local result = collector.collect_selection(buf, 42, 42)
      assert.equals("@file:single.lua:L42-L42", result)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("file_to_context", function()
    it("should convert file path to context format", function()
      local cwd = vim.fn.getcwd()
      local result = collector.file_to_context("test.lua")
      assert.is_not_nil(result:match("^@file:"))
    end)

    it("should expand tilde in path", function()
      local result = collector.file_to_context("~/test.lua")
      assert.is_not_nil(result:match("^@file:"))
      assert.is_nil(result:match("~"))
    end)

    it("should handle relative paths", function()
      local result = collector.file_to_context("./src/main.lua")
      assert.is_not_nil(result:match("^@file:"))
    end)

    it("should handle absolute paths", function()
      local result = collector.file_to_context("/absolute/path/file.lua")
      assert.is_not_nil(result:match("^@file:"))
    end)
  end)

  describe("collect_buffers", function()
    it("should return empty list when no valid buffers", function()
      -- Close all buffers except current
      local current = vim.api.nvim_get_current_buf()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if buf ~= current and vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end

      local result = collector.collect_buffers()
      assert.is_table(result)
    end)

    it("should collect valid file buffers", function()
      local buf1 = vim.api.nvim_create_buf(true, false)
      local buf2 = vim.api.nvim_create_buf(true, false)
      local cwd = vim.fn.getcwd()

      vim.api.nvim_buf_set_name(buf1, cwd .. "/file1.lua")
      vim.api.nvim_buf_set_name(buf2, cwd .. "/file2.lua")

      local result = collector.collect_buffers()

      local has_file1 = false
      local has_file2 = false
      for _, ctx in ipairs(result) do
        if ctx:match("file1%.lua") then
          has_file1 = true
        end
        if ctx:match("file2%.lua") then
          has_file2 = true
        end
      end

      assert.is_true(has_file1)
      assert.is_true(has_file2)

      vim.api.nvim_buf_delete(buf1, { force = true })
      vim.api.nvim_buf_delete(buf2, { force = true })
    end)

    it("should exclude special buffers", function()
      local special_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[special_buf].buftype = "nofile"
      vim.api.nvim_buf_set_name(special_buf, "special")

      local result = collector.collect_buffers()

      local has_special = false
      for _, ctx in ipairs(result) do
        if ctx:match("special") then
          has_special = true
        end
      end

      assert.is_false(has_special)

      vim.api.nvim_buf_delete(special_buf, { force = true })
    end)
  end)
end)
