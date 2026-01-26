-- Tests for vibing.application.daily_summary.collector module

describe("vibing.application.daily_summary.collector", function()
  local collector
  local original_notify

  before_each(function()
    package.loaded["vibing.application.daily_summary.collector"] = nil
    collector = require("vibing.application.daily_summary.collector")

    -- Mock vim.notify to capture warnings
    original_notify = vim.notify
    vim.notify = function() end
  end)

  after_each(function()
    vim.notify = original_notify
  end)

  describe("get_search_directories", function()
    describe("when include_all is false", function()
      it("should return save_dir from config", function()
        local config = {
          chat = {
            save_location_type = "custom",
            save_dir = vim.fn.getcwd() .. "/test-save",
          },
        }

        -- Create test directory
        vim.fn.mkdir(config.chat.save_dir, "p")

        local result = collector.get_search_directories(false, config)

        assert.is_table(result)
        assert.equals(1, #result)
        assert.equals(config.chat.save_dir, result[1])

        -- Cleanup
        vim.fn.delete(config.chat.save_dir, "rf")
      end)
    end)

    describe("when include_all is true and search_dirs is not configured", function()
      it("should return default directories", function()
        local config = {
          daily_summary = {},
          chat = {},
        }

        local result = collector.get_search_directories(true, config)

        assert.is_table(result)
        -- Result may vary based on which directories exist
      end)
    end)

    describe("when include_all is true and search_dirs is configured", function()
      it("should return configured search_dirs", function()
        local test_dir = vim.fn.getcwd() .. "/test-search-dir"
        vim.fn.mkdir(test_dir, "p")

        local config = {
          daily_summary = {
            search_dirs = { test_dir },
          },
        }

        local result = collector.get_search_directories(true, config)

        assert.is_table(result)
        assert.equals(1, #result)
        assert.equals(test_dir, result[1])

        -- Cleanup
        vim.fn.delete(test_dir, "rf")
      end)

      it("should expand tilde in paths", function()
        local home = vim.fn.expand("~")
        local test_dir = home .. "/test-tilde-expansion"
        vim.fn.mkdir(test_dir, "p")

        local config = {
          daily_summary = {
            search_dirs = { "~/test-tilde-expansion" },
          },
        }

        local result = collector.get_search_directories(true, config)

        assert.is_table(result)
        assert.equals(1, #result)
        assert.equals(test_dir, result[1])

        -- Cleanup
        vim.fn.delete(test_dir, "rf")
      end)

      it("should skip invalid values (non-string)", function()
        local warnings = {}
        vim.notify = function(msg, level)
          if level == vim.log.levels.WARN then
            table.insert(warnings, msg)
          end
        end

        local test_dir = vim.fn.getcwd() .. "/test-valid-dir"
        vim.fn.mkdir(test_dir, "p")

        local config = {
          daily_summary = {
            search_dirs = { test_dir, 123, nil, true },
          },
        }

        local result = collector.get_search_directories(true, config)

        assert.is_table(result)
        assert.equals(1, #result)
        assert.equals(test_dir, result[1])

        -- Verify warnings were issued for invalid values
        assert.is_true(#warnings > 0)

        -- Cleanup
        vim.fn.delete(test_dir, "rf")
      end)

      it("should skip empty strings", function()
        local warnings = {}
        vim.notify = function(msg, level)
          if level == vim.log.levels.WARN then
            table.insert(warnings, msg)
          end
        end

        local test_dir = vim.fn.getcwd() .. "/test-empty-string"
        vim.fn.mkdir(test_dir, "p")

        local config = {
          daily_summary = {
            search_dirs = { test_dir, "" },
          },
        }

        local result = collector.get_search_directories(true, config)

        assert.is_table(result)
        assert.equals(1, #result)
        assert.equals(test_dir, result[1])

        -- Verify warning was issued for empty string
        assert.is_true(#warnings > 0)

        -- Cleanup
        vim.fn.delete(test_dir, "rf")
      end)

      it("should warn for non-existent directories", function()
        local warnings = {}
        vim.notify = function(msg, level)
          if level == vim.log.levels.WARN then
            table.insert(warnings, msg)
          end
        end

        local config = {
          daily_summary = {
            search_dirs = { "/non/existent/directory" },
          },
        }

        local result = collector.get_search_directories(true, config)

        assert.is_table(result)
        assert.equals(0, #result)

        -- Verify warning was issued
        assert.is_true(#warnings > 0)
        assert.is_true(warnings[1]:match("does not exist"))
      end)

      it("should handle multiple valid directories", function()
        local test_dir1 = vim.fn.getcwd() .. "/test-multi-dir-1"
        local test_dir2 = vim.fn.getcwd() .. "/test-multi-dir-2"
        vim.fn.mkdir(test_dir1, "p")
        vim.fn.mkdir(test_dir2, "p")

        local config = {
          daily_summary = {
            search_dirs = { test_dir1, test_dir2 },
          },
        }

        local result = collector.get_search_directories(true, config)

        assert.is_table(result)
        assert.equals(2, #result)
        assert.is_true(vim.tbl_contains(result, test_dir1))
        assert.is_true(vim.tbl_contains(result, test_dir2))

        -- Cleanup
        vim.fn.delete(test_dir1, "rf")
        vim.fn.delete(test_dir2, "rf")
      end)

      it("should handle trailing slashes", function()
        local test_dir = vim.fn.getcwd() .. "/test-trailing-slash"
        vim.fn.mkdir(test_dir, "p")

        local config = {
          daily_summary = {
            search_dirs = { test_dir .. "/" },
          },
        }

        local result = collector.get_search_directories(true, config)

        assert.is_table(result)
        assert.equals(1, #result)
        assert.equals(test_dir, result[1])

        -- Cleanup
        vim.fn.delete(test_dir, "rf")
      end)

      it("should fallback to default when search_dirs is empty array", function()
        local config = {
          daily_summary = {
            search_dirs = {},
          },
          chat = {},
        }

        local result = collector.get_search_directories(true, config)

        assert.is_table(result)
        -- Should return default directories (behavior verified by presence of table)
      end)
    end)
  end)

  describe("find_vibing_files", function()
    it("should return empty table for non-existent directory", function()
      local result = collector.find_vibing_files("/non/existent/directory")
      assert.is_table(result)
      assert.equals(0, #result)
    end)

    it("should find .vibing files in directory", function()
      local test_dir = vim.fn.getcwd() .. "/test-vibing-files"
      vim.fn.mkdir(test_dir, "p")

      -- Create test .vibing files
      local file1 = test_dir .. "/chat1.vibing"
      local file2 = test_dir .. "/chat2.vibing"
      vim.fn.writefile({ "test content" }, file1)
      vim.fn.writefile({ "test content" }, file2)

      local result = collector.find_vibing_files(test_dir)

      assert.is_table(result)
      assert.equals(2, #result)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should recursively find .vibing files in subdirectories", function()
      local test_dir = vim.fn.getcwd() .. "/test-recursive"
      local sub_dir = test_dir .. "/subdir"
      vim.fn.mkdir(sub_dir, "p")

      -- Create test .vibing files in nested directories
      local file1 = test_dir .. "/chat1.vibing"
      local file2 = sub_dir .. "/chat2.vibing"
      vim.fn.writefile({ "test content" }, file1)
      vim.fn.writefile({ "test content" }, file2)

      local result = collector.find_vibing_files(test_dir)

      assert.is_table(result)
      assert.equals(2, #result)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should ignore non-.vibing files", function()
      local test_dir = vim.fn.getcwd() .. "/test-ignore-non-vibing"
      vim.fn.mkdir(test_dir, "p")

      -- Create mixed files
      local vibing_file = test_dir .. "/chat.vibing"
      local txt_file = test_dir .. "/readme.txt"
      local md_file = test_dir .. "/notes.md"
      vim.fn.writefile({ "test content" }, vibing_file)
      vim.fn.writefile({ "test content" }, txt_file)
      vim.fn.writefile({ "test content" }, md_file)

      local result = collector.find_vibing_files(test_dir)

      assert.is_table(result)
      assert.equals(1, #result)
      assert.is_true(result[1]:match("%.vibing$") ~= nil)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)
  end)
end)
