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
        -- Should return at least one default directory (behavior verified by non-empty result)
        assert.is_true(#result > 0, "Expected at least one default directory, got empty result")

        -- Verify default directories are included (project/.md/chat and/or user data dir)
        local project_root = vim.fn.getcwd()
        local expected_defaults = {
          project_root .. "/.md/chat",
          vim.fn.stdpath("data") .. "/vibing/chats",
        }

        -- At least one default directory should be in the result
        local has_default = false
        for _, expected in ipairs(expected_defaults) do
          for _, actual in ipairs(result) do
            if actual == expected then
              has_default = true
              break
            end
          end
        end
        assert.is_true(has_default, "Expected result to contain at least one default directory")
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
        assert.is_not_nil(warnings[1]:match("does not exist"))
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

        -- Get expected default behavior
        local expected_defaults = collector.get_search_directories(true, {
          daily_summary = nil,
          chat = {},
        })

        assert.is_table(result)
        assert.is_table(expected_defaults)

        -- Empty array should produce same result as nil/unconfigured
        assert.same(result, expected_defaults, "Empty search_dirs should fallback to default directories")
      end)
    end)
  end)

  describe("find_vibing_files", function()
    it("should return empty table for non-existent directory", function()
      local result = collector.find_vibing_files("/non/existent/directory")
      assert.is_table(result)
      assert.equals(0, #result)
    end)

    it("should find .md files in directory", function()
      local test_dir = vim.fn.getcwd() .. "/test-vibing-files"
      vim.fn.mkdir(test_dir, "p")

      -- Create test .md files
      local file1 = test_dir .. "/chat1.md"
      local file2 = test_dir .. "/chat2.md"
      vim.fn.writefile({ "test content" }, file1)
      vim.fn.writefile({ "test content" }, file2)

      local result = collector.find_vibing_files(test_dir)

      assert.is_table(result)
      assert.equals(2, #result)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should recursively find .md files in subdirectories", function()
      local test_dir = vim.fn.getcwd() .. "/test-recursive"
      local sub_dir = test_dir .. "/subdir"
      vim.fn.mkdir(sub_dir, "p")

      -- Create test .md files in nested directories
      local file1 = test_dir .. "/chat1.md"
      local file2 = sub_dir .. "/chat2.md"
      vim.fn.writefile({ "test content" }, file1)
      vim.fn.writefile({ "test content" }, file2)

      local result = collector.find_vibing_files(test_dir)

      assert.is_table(result)
      assert.equals(2, #result)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should ignore non-.md files", function()
      local test_dir = vim.fn.getcwd() .. "/test-ignore-non-vibing"
      -- Clean up if directory exists from previous run
      vim.fn.delete(test_dir, "rf")
      vim.fn.mkdir(test_dir, "p")

      -- Create mixed files
      local vibing_file = test_dir .. "/chat.md"
      local txt_file = test_dir .. "/readme.txt"
      local md_file = test_dir .. "/notes.md"
      -- chat.md has vibing.nvim frontmatter
      vim.fn.writefile({
        "---",
        "vibing.nvim: true",
        "session_id: test-session",
        "---",
        "",
        "## User",
        "",
        "test content",
      }, vibing_file)
      vim.fn.writefile({ "test content" }, txt_file)
      -- notes.md is a regular markdown file without vibing.nvim frontmatter
      vim.fn.writefile({ "# Notes", "", "Some notes content" }, md_file)

      local result = collector.find_vibing_files(test_dir)

      assert.is_table(result)
      -- find_vibing_files returns all .md files (filtering happens in collect_messages_from_file)
      assert.equals(2, #result)
      -- Should not include .txt file
      for _, file in ipairs(result) do
        assert.is_nil(file:match("%.txt$"))
      end

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should handle symlink circular references without infinite loop", function()
      local test_dir = vim.fn.getcwd() .. "/test-symlink-circular"
      local dir_a = test_dir .. "/dir_a"
      local dir_b = test_dir .. "/dir_b"
      vim.fn.mkdir(dir_a, "p")
      vim.fn.mkdir(dir_b, "p")

      -- Create .md files in both directories
      local file_a = dir_a .. "/chat_a.md"
      local file_b = dir_b .. "/chat_b.md"
      vim.fn.writefile({ "test content a" }, file_a)
      vim.fn.writefile({ "test content b" }, file_b)

      -- Create circular symlinks: dir_a/link_b -> dir_b, dir_b/link_a -> dir_a
      vim.loop.fs_symlink(dir_b, dir_a .. "/link_b", { dir = true })
      vim.loop.fs_symlink(dir_a, dir_b .. "/link_a", { dir = true })

      -- Should not hang - finds files from both directories once
      local result = collector.find_vibing_files(test_dir)

      assert.is_table(result)
      -- Should find exactly 2 files (not infinite loop)
      assert.equals(2, #result)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)

    it("should handle symlink to parent directory without infinite loop", function()
      local test_dir = vim.fn.getcwd() .. "/test-symlink-parent"
      local sub_dir = test_dir .. "/subdir"
      vim.fn.mkdir(sub_dir, "p")

      -- Create .md file in test_dir
      local vibing_file = test_dir .. "/chat.md"
      vim.fn.writefile({ "test content" }, vibing_file)

      -- Create symlink from subdir back to parent: subdir/link_parent -> ..
      vim.loop.fs_symlink(test_dir, sub_dir .. "/link_parent", { dir = true })

      -- Should not hang
      local result = collector.find_vibing_files(test_dir)

      assert.is_table(result)
      -- Should find exactly 1 file (not infinite loop)
      assert.equals(1, #result)

      -- Cleanup
      vim.fn.delete(test_dir, "rf")
    end)
  end)
end)
