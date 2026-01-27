describe("vibing.infrastructure.file_finder.ripgrep_command", function()
  local ripgrep_command = require("vibing.infrastructure.file_finder.ripgrep_command")

  local function skip_if_unsupported(finder)
    if not finder:supports_platform() then
      pending("rg command not available on this platform")
      return true
    end
    return false
  end

  describe("new", function()
    it("should create instance with correct name", function()
      local finder = ripgrep_command:new()
      assert.equals("ripgrep_command", finder.name)
    end)

    it("should accept mtime_days option", function()
      local finder = ripgrep_command:new({ mtime_days = 7 })
      assert.equals(7, finder.mtime_days)
    end)
  end)

  describe("supports_platform", function()
    it("should return boolean indicating rg availability", function()
      local finder = ripgrep_command:new()
      local supported = finder:supports_platform()
      assert.is_boolean(supported)
    end)
  end)

  describe("find", function()
    it("should return error for non-existent directory", function()
      local finder = ripgrep_command:new()
      if skip_if_unsupported(finder) then return end

      local files, err = finder:find("/non/existent/path", "*.vibing")
      assert.is_table(files)
      assert.equals(0, #files)
      assert.is_not_nil(err)
    end)

    it("should find files matching pattern", function()
      local finder = ripgrep_command:new()
      if skip_if_unsupported(finder) then return end

      local test_dir = vim.fn.getcwd() .. "/test-rg-find"
      vim.fn.mkdir(test_dir, "p")
      vim.fn.writefile({ "test" }, test_dir .. "/test.vibing")
      vim.fn.writefile({ "test" }, test_dir .. "/test.txt")

      local files, err = finder:find(test_dir, "*.vibing")

      assert.is_nil(err)
      assert.is_table(files)
      assert.equals(1, #files)
      assert.is_true(files[1]:match("test%.vibing$") ~= nil)

      vim.fn.delete(test_dir, "rf")
    end)

    it("should find files recursively in subdirectories", function()
      local finder = ripgrep_command:new()
      if skip_if_unsupported(finder) then return end

      local test_dir = vim.fn.getcwd() .. "/test-rg-recursive"
      local sub_dir = test_dir .. "/subdir/nested"
      vim.fn.mkdir(sub_dir, "p")
      vim.fn.writefile({ "test" }, test_dir .. "/root.vibing")
      vim.fn.writefile({ "test" }, sub_dir .. "/nested.vibing")

      local files, err = finder:find(test_dir, "*.vibing")

      assert.is_nil(err)
      assert.is_table(files)
      assert.equals(2, #files)

      vim.fn.delete(test_dir, "rf")
    end)

    it("should filter by mtime when mtime_days is specified", function()
      local finder = ripgrep_command:new({ mtime_days = 1 })
      if skip_if_unsupported(finder) then return end

      local test_dir = vim.fn.getcwd() .. "/test-rg-mtime"
      vim.fn.mkdir(test_dir, "p")
      vim.fn.writefile({ "test" }, test_dir .. "/recent.vibing")

      local files, err = finder:find(test_dir, "*.vibing")

      assert.is_nil(err)
      assert.is_table(files)
      assert.equals(1, #files)

      vim.fn.delete(test_dir, "rf")
    end)
  end)
end)
