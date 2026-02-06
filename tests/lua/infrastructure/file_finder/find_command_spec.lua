-- Tests for vibing.infrastructure.file_finder.find_command module

describe("vibing.infrastructure.file_finder.find_command", function()
  local find_command

  before_each(function()
    package.loaded["vibing.infrastructure.file_finder.find_command"] = nil
    find_command = require("vibing.infrastructure.file_finder.find_command")
  end)

  describe("new", function()
    it("should create instance with correct name", function()
      local finder = find_command:new()
      assert.equals("find_command", finder.name)
    end)
  end)

  describe("supports_platform", function()
    it("should return boolean indicating find command availability", function()
      local finder = find_command:new()
      local result = finder:supports_platform()
      assert.is_boolean(result)

      if not result then
        pending("skipping: find command unavailable on this platform")
        return
      end

      -- On macOS/Linux, find command should be available
      assert.is_true(result, "find command should be available on macOS/Linux")
    end)
  end)

  describe("find", function()
    local function skip_if_unsupported(finder)
      if not finder:supports_platform() then
        pending("skipping: find command unavailable on this platform")
        return true
      end
      return false
    end

    it("should return error for non-existent directory", function()
      local finder = find_command:new()
      if skip_if_unsupported(finder) then return end

      local files, err = finder:find("/non/existent/directory", "*.md")

      assert.is_table(files)
      assert.equals(0, #files)
      assert.is_string(err)
      assert.is_true(err:match("does not exist") ~= nil)
    end)

    it("should find files matching pattern", function()
      local finder = find_command:new()
      if skip_if_unsupported(finder) then return end

      local test_dir = vim.fn.getcwd() .. "/test-find-command"
      vim.fn.mkdir(test_dir, "p")

      -- Create test files
      local file1 = test_dir .. "/chat1.md"
      local file2 = test_dir .. "/chat2.md"
      local file3 = test_dir .. "/readme.txt"
      vim.fn.writefile({ "test" }, file1)
      vim.fn.writefile({ "test" }, file2)
      vim.fn.writefile({ "test" }, file3)

      local files, err = finder:find(test_dir, "*.md")

      assert.is_nil(err)
      assert.is_table(files)
      assert.equals(2, #files)

      -- Verify all found files match pattern
      for _, f in ipairs(files) do
        assert.is_true(f:match("%.md$") ~= nil)
      end

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should find files recursively in subdirectories", function()
      local finder = find_command:new()
      if skip_if_unsupported(finder) then return end

      local test_dir = vim.fn.getcwd() .. "/test-find-recursive"
      local sub_dir = test_dir .. "/subdir"
      vim.fn.mkdir(sub_dir, "p")

      -- Create test files
      local file1 = test_dir .. "/chat1.md"
      local file2 = sub_dir .. "/chat2.md"
      vim.fn.writefile({ "test" }, file1)
      vim.fn.writefile({ "test" }, file2)

      local files, err = finder:find(test_dir, "*.md")

      assert.is_nil(err)
      assert.is_table(files)
      assert.equals(2, #files)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should return empty array for directory with no matching files", function()
      local finder = find_command:new()
      if skip_if_unsupported(finder) then return end

      local test_dir = vim.fn.getcwd() .. "/test-find-empty"
      vim.fn.mkdir(test_dir, "p")

      -- Create non-matching file
      vim.fn.writefile({ "test" }, test_dir .. "/readme.txt")

      local files, err = finder:find(test_dir, "*.md")

      assert.is_nil(err)
      assert.is_table(files)
      assert.equals(0, #files)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should not follow symlinks (prevent circular reference)", function()
      local finder = find_command:new()
      if skip_if_unsupported(finder) then return end

      local test_dir = vim.fn.getcwd() .. "/test-find-symlink"
      local sub_dir = test_dir .. "/subdir"
      vim.fn.mkdir(sub_dir, "p")

      -- Create test file
      vim.fn.writefile({ "test" }, test_dir .. "/chat.md")

      -- Create symlink back to parent (potential infinite loop)
      vim.loop.fs_symlink(test_dir, sub_dir .. "/link_parent", { dir = true })

      -- Should complete without hanging (using -P flag)
      local files, err = finder:find(test_dir, "*.md")

      assert.is_nil(err)
      assert.is_table(files)
      -- Should find exactly 1 file (not infinite)
      assert.equals(1, #files)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should filter by mtime when mtime_days is specified", function()
      local finder = find_command:new({ mtime_days = 1 })
      if skip_if_unsupported(finder) then return end

      local test_dir = vim.fn.getcwd() .. "/test-find-mtime"
      vim.fn.mkdir(test_dir, "p")

      -- Create test file (will be recently modified)
      local file1 = test_dir .. "/recent.md"
      vim.fn.writefile({ "test" }, file1)

      -- Find with mtime filter (files modified within 1 day)
      local files, err = finder:find(test_dir, "*.md")

      assert.is_nil(err)
      assert.is_table(files)
      -- Recently created file should be found
      assert.equals(1, #files)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should use custom prune_dirs when specified", function()
      local finder = find_command:new({ prune_dirs = { "custom_ignore" } })
      if skip_if_unsupported(finder) then return end

      local test_dir = vim.fn.getcwd() .. "/test-find-prune"
      local ignored_dir = test_dir .. "/custom_ignore"
      vim.fn.mkdir(ignored_dir, "p")

      -- Create files
      vim.fn.writefile({ "test" }, test_dir .. "/visible.md")
      vim.fn.writefile({ "test" }, ignored_dir .. "/hidden.md")

      local files, err = finder:find(test_dir, "*.md")

      assert.is_nil(err)
      assert.is_table(files)
      -- Only visible.md should be found (custom_ignore is pruned)
      assert.equals(1, #files)
      assert.is_true(files[1]:match("visible%.md$") ~= nil)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)
  end)
end)
