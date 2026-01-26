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
    it("should return true on macOS/Linux", function()
      local finder = find_command:new()
      -- On macOS/Linux, find command should be available
      local result = finder:supports_platform()
      assert.is_boolean(result)
      -- This test assumes running on macOS/Linux
      assert.is_true(result, "find command should be available on macOS/Linux")
    end)
  end)

  describe("find", function()
    it("should return error for non-existent directory", function()
      local finder = find_command:new()
      local files, err = finder:find("/non/existent/directory", "*.vibing")

      assert.is_table(files)
      assert.equals(0, #files)
      assert.is_string(err)
      assert.is_true(err:match("does not exist") ~= nil)
    end)

    it("should find files matching pattern", function()
      local finder = find_command:new()
      local test_dir = vim.fn.getcwd() .. "/test-find-command"
      vim.fn.mkdir(test_dir, "p")

      -- Create test files
      local file1 = test_dir .. "/chat1.vibing"
      local file2 = test_dir .. "/chat2.vibing"
      local file3 = test_dir .. "/readme.txt"
      vim.fn.writefile({ "test" }, file1)
      vim.fn.writefile({ "test" }, file2)
      vim.fn.writefile({ "test" }, file3)

      local files, err = finder:find(test_dir, "*.vibing")

      assert.is_nil(err)
      assert.is_table(files)
      assert.equals(2, #files)

      -- Verify all found files match pattern
      for _, f in ipairs(files) do
        assert.is_true(f:match("%.vibing$") ~= nil)
      end

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should find files recursively in subdirectories", function()
      local finder = find_command:new()
      local test_dir = vim.fn.getcwd() .. "/test-find-recursive"
      local sub_dir = test_dir .. "/subdir"
      vim.fn.mkdir(sub_dir, "p")

      -- Create test files
      local file1 = test_dir .. "/chat1.vibing"
      local file2 = sub_dir .. "/chat2.vibing"
      vim.fn.writefile({ "test" }, file1)
      vim.fn.writefile({ "test" }, file2)

      local files, err = finder:find(test_dir, "*.vibing")

      assert.is_nil(err)
      assert.is_table(files)
      assert.equals(2, #files)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should return empty array for directory with no matching files", function()
      local finder = find_command:new()
      local test_dir = vim.fn.getcwd() .. "/test-find-empty"
      vim.fn.mkdir(test_dir, "p")

      -- Create non-matching file
      vim.fn.writefile({ "test" }, test_dir .. "/readme.txt")

      local files, err = finder:find(test_dir, "*.vibing")

      assert.is_nil(err)
      assert.is_table(files)
      assert.equals(0, #files)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should not follow symlinks (prevent circular reference)", function()
      local finder = find_command:new()
      local test_dir = vim.fn.getcwd() .. "/test-find-symlink"
      local sub_dir = test_dir .. "/subdir"
      vim.fn.mkdir(sub_dir, "p")

      -- Create test file
      vim.fn.writefile({ "test" }, test_dir .. "/chat.vibing")

      -- Create symlink back to parent (potential infinite loop)
      vim.loop.fs_symlink(test_dir, sub_dir .. "/link_parent", { dir = true })

      -- Should complete without hanging (using -P flag)
      local files, err = finder:find(test_dir, "*.vibing")

      assert.is_nil(err)
      assert.is_table(files)
      -- Should find exactly 1 file (not infinite)
      assert.equals(1, #files)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)
  end)
end)
