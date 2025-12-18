-- Tests for vibing.context module

describe("vibing.context", function()
  local Context
  local mock_collector

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.context"] = nil
    package.loaded["vibing.context.collector"] = nil

    -- Mock Collector
    mock_collector = {
      file_to_context = function(path)
        return "@file:" .. path
      end,
      collect_buffers = function()
        return { "@file:auto1.lua", "@file:auto2.lua" }
      end,
      collect_selection = function(buf, start_line, end_line)
        return string.format("@file:selection.lua:L%d-L%d", start_line, end_line)
      end,
    }
    package.loaded["vibing.context.collector"] = mock_collector

    Context = require("vibing.context")
  end)

  after_each(function()
    -- Reset state
    if Context then
      Context.manual_contexts = {}
    end
  end)

  describe("add", function()
    it("should add file context when path provided", function()
      Context.add("/path/to/file.lua")

      assert.equals(1, #Context.manual_contexts)
      assert.equals("@file:/path/to/file.lua", Context.manual_contexts[1])
    end)

    it("should not add duplicate contexts", function()
      Context.add("/path/to/file.lua")
      Context.add("/path/to/file.lua")

      assert.equals(1, #Context.manual_contexts)
    end)

    it("should add multiple different contexts", function()
      Context.add("/path/to/file1.lua")
      Context.add("/path/to/file2.lua")

      assert.equals(2, #Context.manual_contexts)
      assert.equals("@file:/path/to/file1.lua", Context.manual_contexts[1])
      assert.equals("@file:/path/to/file2.lua", Context.manual_contexts[2])
    end)

    it("should use current buffer when no path provided", function()
      -- Mock vim APIs
      local original_get_current_buf = vim.api.nvim_get_current_buf
      local original_buf_get_name = vim.api.nvim_buf_get_name

      vim.api.nvim_get_current_buf = function()
        return 1
      end
      vim.api.nvim_buf_get_name = function(buf)
        assert.equals(1, buf)
        return "/current/buffer.lua"
      end

      Context.add()

      assert.equals(1, #Context.manual_contexts)
      assert.equals("@file:/current/buffer.lua", Context.manual_contexts[1])

      -- Restore
      vim.api.nvim_get_current_buf = original_get_current_buf
      vim.api.nvim_buf_get_name = original_buf_get_name
    end)

    it("should handle empty string path as current buffer", function()
      local original_get_current_buf = vim.api.nvim_get_current_buf
      local original_buf_get_name = vim.api.nvim_buf_get_name

      vim.api.nvim_get_current_buf = function()
        return 1
      end
      vim.api.nvim_buf_get_name = function()
        return "/current/buffer.lua"
      end

      Context.add("")

      assert.equals(1, #Context.manual_contexts)
      assert.equals("@file:/current/buffer.lua", Context.manual_contexts[1])

      -- Restore
      vim.api.nvim_get_current_buf = original_get_current_buf
      vim.api.nvim_buf_get_name = original_buf_get_name
    end)

    it("should warn when current buffer has no file path", function()
      local original_get_current_buf = vim.api.nvim_get_current_buf
      local original_buf_get_name = vim.api.nvim_buf_get_name

      vim.api.nvim_get_current_buf = function()
        return 1
      end
      vim.api.nvim_buf_get_name = function()
        return ""
      end

      Context.add()

      -- Should not add anything
      assert.equals(0, #Context.manual_contexts)

      -- Restore
      vim.api.nvim_get_current_buf = original_get_current_buf
      vim.api.nvim_buf_get_name = original_buf_get_name
    end)
  end)

  describe("clear", function()
    it("should clear all manual contexts", function()
      Context.add("/path/to/file1.lua")
      Context.add("/path/to/file2.lua")
      assert.equals(2, #Context.manual_contexts)

      Context.clear()

      assert.equals(0, #Context.manual_contexts)
    end)

    it("should work when no contexts exist", function()
      assert.equals(0, #Context.manual_contexts)

      -- Should not error
      Context.clear()

      assert.equals(0, #Context.manual_contexts)
    end)
  end)

  describe("get_all", function()
    it("should return only manual contexts when auto_context is false", function()
      Context.add("/path/to/manual.lua")

      local result = Context.get_all(false)

      assert.equals(1, #result)
      assert.equals("@file:/path/to/manual.lua", result[1])
    end)

    it("should return empty array when no contexts", function()
      local result = Context.get_all(false)

      assert.same({}, result)
    end)

    it("should include auto contexts when auto_context is true", function()
      Context.add("/path/to/manual.lua")

      local result = Context.get_all(true)

      assert.equals(3, #result)
      assert.equals("@file:/path/to/manual.lua", result[1])
      assert.equals("@file:auto1.lua", result[2])
      assert.equals("@file:auto2.lua", result[3])
    end)

    it("should not include duplicate auto contexts", function()
      Context.add("/path/to/auto1.lua")

      local result = Context.get_all(true)

      -- Should only include auto1.lua once (from manual)
      assert.equals(3, #result)
      local count = 0
      for _, ctx in ipairs(result) do
        if ctx == "@file:auto1.lua" or ctx == "@file:/path/to/auto1.lua" then
          count = count + 1
        end
      end
      assert.equals(2, count) -- One manual, one auto (different paths)
    end)

    it("should return only auto contexts when no manual contexts", function()
      local result = Context.get_all(true)

      assert.equals(2, #result)
      assert.equals("@file:auto1.lua", result[1])
      assert.equals("@file:auto2.lua", result[2])
    end)
  end)

  describe("get_selection", function()
    it("should call Collector.collect_selection with correct parameters", function()
      local original_get_current_buf = vim.api.nvim_get_current_buf
      local original_getpos = vim.fn.getpos

      vim.api.nvim_get_current_buf = function()
        return 42
      end
      vim.fn.getpos = function(mark)
        if mark == "'<" then
          return { 0, 10, 0, 0 }
        elseif mark == "'>" then
          return { 0, 20, 0, 0 }
        end
      end

      local result = Context.get_selection()

      assert.equals("@file:selection.lua:L10-L20", result)

      -- Restore
      vim.api.nvim_get_current_buf = original_get_current_buf
      vim.fn.getpos = original_getpos
    end)
  end)

  describe("format_for_display", function()
    it("should format auto contexts when no manual contexts", function()
      -- format_for_display calls get_all(true), so it includes auto contexts
      local result = Context.format_for_display()

      -- Should contain auto contexts from mock
      assert.is_not_nil(result:match("@file:auto1.lua"))
      assert.is_not_nil(result:match("@file:auto2.lua"))
    end)

    it("should format contexts with comma separation", function()
      Context.add("/path/to/file1.lua")
      Context.add("/path/to/file2.lua")

      local result = Context.format_for_display()

      -- Should include manual contexts plus auto contexts
      assert.is_not_nil(result:match("@file:/path/to/file1.lua"))
      assert.is_not_nil(result:match("@file:/path/to/file2.lua"))
      assert.is_not_nil(result:match("@file:auto1.lua"))
      assert.is_not_nil(result:match("@file:auto2.lua"))
    end)
  end)

  describe("integration", function()
    it("should handle full context lifecycle", function()
      -- Add contexts
      Context.add("/path/to/file1.lua")
      Context.add("/path/to/file2.lua")
      assert.equals(2, #Context.manual_contexts)

      -- Get all with auto
      local all = Context.get_all(true)
      assert.equals(4, #all) -- 2 manual + 2 auto

      -- Format
      local display = Context.format_for_display()
      assert.is_not_nil(display:match("file1.lua"))

      -- Clear
      Context.clear()
      assert.equals(0, #Context.manual_contexts)

      -- Get after clear
      local after_clear = Context.get_all(true)
      assert.equals(2, #after_clear) -- Only auto contexts remain
    end)
  end)
end)
