-- Tests for vibing.context.migrator module

describe("vibing.context.migrator", function()
  local Migrator
  local test_dir

  before_each(function()
    package.loaded["vibing.context.migrator"] = nil
    Migrator = require("vibing.context.migrator")

    -- Create temp directory for test files
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")
  end)

  after_each(function()
    -- Clean up temp directory
    if vim.fn.isdirectory(test_dir) == 1 then
      vim.fn.delete(test_dir, "rf")
    end
  end)

  describe("detect_old_format", function()
    it("should return false for non-existent file", function()
      local result = Migrator.detect_old_format("/nonexistent/file.md")
      assert.is_false(result)
    end)

    it("should detect old format with Context at top", function()
      local test_file = test_dir .. "/old_format.md"
      local lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "Context: @file:test.lua",
        "",
        "## User",
        "Hello",
      }
      vim.fn.writefile(lines, test_file)

      local result = Migrator.detect_old_format(test_file)
      assert.is_true(result)
    end)

    it("should return false for new format with Context at bottom", function()
      local test_file = test_dir .. "/new_format.md"
      local lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "## User",
        "Hello",
        "",
        "Context: @file:test.lua",
      }
      vim.fn.writefile(lines, test_file)

      local result = Migrator.detect_old_format(test_file)
      assert.is_false(result)
    end)

    it("should return false when no Context line exists", function()
      local test_file = test_dir .. "/no_context.md"
      local lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "## User",
        "Hello",
      }
      vim.fn.writefile(lines, test_file)

      local result = Migrator.detect_old_format(test_file)
      assert.is_false(result)
    end)

    it("should handle file without frontmatter", function()
      local test_file = test_dir .. "/no_frontmatter.md"
      local lines = {
        "Context: @file:test.lua",
        "",
        "## User",
        "Hello",
      }
      vim.fn.writefile(lines, test_file)

      local result = Migrator.detect_old_format(test_file)
      assert.is_true(result)
    end)
  end)

  describe("migrate_file", function()
    it("should return error for non-existent file", function()
      local success, error_msg = Migrator.migrate_file("/nonexistent/file.md", false)
      assert.is_false(success)
      assert.is_not_nil(error_msg)
      assert.is_not_nil(error_msg:match("not readable"))
    end)

    it("should migrate Context line to end of file", function()
      local test_file = test_dir .. "/migrate_test.md"
      local original_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "Context: @file:test.lua",
        "",
        "## User",
        "Hello",
        "",
        "## Assistant",
        "Hi there",
      }
      vim.fn.writefile(original_lines, test_file)

      local success, error_msg = Migrator.migrate_file(test_file, false)

      assert.is_true(success)
      assert.is_nil(error_msg)

      local new_lines = vim.fn.readfile(test_file)
      assert.equals("Context: @file:test.lua", new_lines[#new_lines])
      assert.equals("", new_lines[#new_lines - 1])
    end)

    it("should create backup when requested", function()
      local test_file = test_dir .. "/backup_test.md"
      local backup_file = test_file .. ".bak"
      local original_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "Context: @file:test.lua",
        "",
        "## User",
        "Hello",
      }
      vim.fn.writefile(original_lines, test_file)

      local success = Migrator.migrate_file(test_file, true)

      assert.is_true(success)
      assert.equals(1, vim.fn.filereadable(backup_file))

      local backup_lines = vim.fn.readfile(backup_file)
      assert.same(original_lines, backup_lines)
    end)

    it("should not create backup when not requested", function()
      local test_file = test_dir .. "/no_backup_test.md"
      local backup_file = test_file .. ".bak"
      local original_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "Context: @file:test.lua",
        "",
        "## User",
        "Hello",
      }
      vim.fn.writefile(original_lines, test_file)

      Migrator.migrate_file(test_file, false)

      assert.equals(0, vim.fn.filereadable(backup_file))
    end)

    it("should remove trailing empty lines before adding Context", function()
      local test_file = test_dir .. "/trailing_lines.md"
      local original_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "Context: @file:test.lua",
        "",
        "## User",
        "Hello",
        "",
        "",
        "",
      }
      vim.fn.writefile(original_lines, test_file)

      Migrator.migrate_file(test_file, false)

      local new_lines = vim.fn.readfile(test_file)
      -- Should have: frontmatter (3), blank, User section (2), blank, Context
      assert.equals("Context: @file:test.lua", new_lines[#new_lines])
      assert.equals("", new_lines[#new_lines - 1])
      assert.equals("Hello", new_lines[#new_lines - 2])
    end)

    it("should handle file with no Context line", function()
      local test_file = test_dir .. "/no_context.md"
      local original_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "## User",
        "Hello",
      }
      vim.fn.writefile(original_lines, test_file)

      local success = Migrator.migrate_file(test_file, false)

      assert.is_true(success)

      local new_lines = vim.fn.readfile(test_file)
      -- Should be unchanged except for trailing whitespace
      assert.equals("Hello", new_lines[#new_lines])
    end)
  end)

  describe("scan_chat_directory", function()
    it("should return empty list for non-existent directory", function()
      local result = Migrator.scan_chat_directory("/nonexistent/directory")
      assert.same({}, result)
    end)

    it("should find old format files in directory", function()
      -- Create old format file
      local old_file = test_dir .. "/old.md"
      vim.fn.writefile({
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "Context: @file:old.lua",
        "",
        "## User",
        "Test",
      }, old_file)

      -- Create new format file
      local new_file = test_dir .. "/new.md"
      vim.fn.writefile({
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "## User",
        "Test",
        "",
        "Context: @file:new.lua",
      }, new_file)

      local result = Migrator.scan_chat_directory(test_dir)

      assert.equals(1, #result)
      assert.is_not_nil(result[1]:match("old%.md"))
    end)

    it("should find files in subdirectories", function()
      local subdir = test_dir .. "/subdir"
      vim.fn.mkdir(subdir, "p")

      local old_file = subdir .. "/old.md"
      vim.fn.writefile({
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "Context: @file:test.lua",
        "",
        "## User",
        "Test",
      }, old_file)

      local result = Migrator.scan_chat_directory(test_dir)

      assert.equals(1, #result)
      assert.is_not_nil(result[1]:match("subdir/old%.md"))
    end)

    it("should return empty list when no old format files exist", function()
      -- Create only new format files
      local new_file = test_dir .. "/new.md"
      vim.fn.writefile({
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "## User",
        "Test",
      }, new_file)

      local result = Migrator.scan_chat_directory(test_dir)

      assert.same({}, result)
    end)
  end)

  describe("migrate_current_buffer", function()
    it("should return error when no file path", function()
      local mock_buffer = {}

      local success, error_msg = Migrator.migrate_current_buffer(mock_buffer)

      assert.is_false(success)
      assert.is_not_nil(error_msg)
      assert.is_not_nil(error_msg:match("No file path"))
    end)

    it("should migrate buffer file with backup", function()
      local test_file = test_dir .. "/buffer_test.md"
      local original_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "",
        "Context: @file:test.lua",
        "",
        "## User",
        "Hello",
      }
      vim.fn.writefile(original_lines, test_file)

      local mock_buffer = {
        file_path = test_file,
      }

      local success = Migrator.migrate_current_buffer(mock_buffer)

      assert.is_true(success)

      -- Check backup was created
      local backup_file = test_file .. ".bak"
      assert.equals(1, vim.fn.filereadable(backup_file))

      -- Check migration happened
      local new_lines = vim.fn.readfile(test_file)
      assert.equals("Context: @file:test.lua", new_lines[#new_lines])
    end)
  end)

  describe("integration", function()
    it("should support full migration workflow", function()
      -- Create old format file
      local old_file = test_dir .. "/workflow.md"
      vim.fn.writefile({
        "---",
        "vibing.nvim: true",
        "session_id: test-123",
        "---",
        "",
        "Context: @file:test.lua, @file:utils.lua",
        "",
        "## User",
        "First message",
        "",
        "## Assistant",
        "Response",
        "",
        "## User",
        "Second message",
      }, old_file)

      -- Detect old format
      assert.is_true(Migrator.detect_old_format(old_file))

      -- Migrate with backup
      local success = Migrator.migrate_file(old_file, true)
      assert.is_true(success)

      -- Verify backup exists
      assert.equals(1, vim.fn.filereadable(old_file .. ".bak"))

      -- Verify new format
      assert.is_false(Migrator.detect_old_format(old_file))

      local new_lines = vim.fn.readfile(old_file)
      assert.equals("Context: @file:test.lua, @file:utils.lua", new_lines[#new_lines])

      -- Verify content intact (except Context position)
      local has_first_message = false
      local has_second_message = false
      for _, line in ipairs(new_lines) do
        if line:match("First message") then
          has_first_message = true
        end
        if line:match("Second message") then
          has_second_message = true
        end
      end
      assert.is_true(has_first_message)
      assert.is_true(has_second_message)
    end)
  end)
end)
