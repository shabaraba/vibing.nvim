-- Tests for vibing.infrastructure.file_finder.scandir module

describe("vibing.infrastructure.file_finder.scandir", function()
  local scandir

  before_each(function()
    package.loaded["vibing.infrastructure.file_finder.scandir"] = nil
    scandir = require("vibing.infrastructure.file_finder.scandir")
  end)

  describe("new", function()
    it("should create instance with correct name", function()
      local finder = scandir:new()
      assert.equals("scandir", finder.name)
    end)
  end)

  describe("supports_platform", function()
    it("should always return true", function()
      local finder = scandir:new()
      assert.is_true(finder:supports_platform())
    end)
  end)

  describe("find", function()
    it("should return error for non-existent directory", function()
      local finder = scandir:new()
      local files, err = finder:find("/non/existent/directory", "*.vibing")

      assert.is_table(files)
      assert.equals(0, #files)
      assert.is_string(err)
      assert.is_true(err:match("does not exist") ~= nil)
    end)

    it("should find files matching pattern", function()
      local finder = scandir:new()
      local test_dir = vim.fn.getcwd() .. "/test-scandir"
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
      local finder = scandir:new()
      local test_dir = vim.fn.getcwd() .. "/test-scandir-recursive"
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

    it("should handle symlink circular references without infinite loop", function()
      local finder = scandir:new()
      local test_dir = vim.fn.getcwd() .. "/test-scandir-symlink"
      local dir_a = test_dir .. "/dir_a"
      local dir_b = test_dir .. "/dir_b"
      vim.fn.mkdir(dir_a, "p")
      vim.fn.mkdir(dir_b, "p")

      -- Create test files
      vim.fn.writefile({ "test" }, dir_a .. "/chat_a.vibing")
      vim.fn.writefile({ "test" }, dir_b .. "/chat_b.vibing")

      -- Create circular symlinks
      vim.loop.fs_symlink(dir_b, dir_a .. "/link_b", { dir = true })
      vim.loop.fs_symlink(dir_a, dir_b .. "/link_a", { dir = true })

      -- Should complete without hanging
      local files, err = finder:find(test_dir, "*.vibing")

      assert.is_nil(err)
      assert.is_table(files)
      assert.equals(2, #files)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should handle various glob patterns", function()
      local finder = scandir:new()
      local test_dir = vim.fn.getcwd() .. "/test-scandir-patterns"
      vim.fn.mkdir(test_dir, "p")

      -- Create test files
      vim.fn.writefile({ "test" }, test_dir .. "/file.txt")
      vim.fn.writefile({ "test" }, test_dir .. "/file.md")
      vim.fn.writefile({ "test" }, test_dir .. "/file.vibing")

      -- Test *.txt pattern
      local txt_files, _ = finder:find(test_dir, "*.txt")
      assert.equals(1, #txt_files)

      -- Test *.md pattern
      local md_files, _ = finder:find(test_dir, "*.md")
      assert.equals(1, #md_files)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)
  end)
end)
