-- Tests for vibing.core.utils.git module

describe("vibing.core.utils.git", function()
  local Git

  before_each(function()
    package.loaded["vibing.core.utils.git"] = nil
    Git = require("vibing.core.utils.git")
  end)

  describe("get_root", function()
    it("should return git root path when in git repository", function()
      -- This test requires running in a git repository
      local root = Git.get_root()
      if root then
        assert.is_string(root)
        assert.is_not_nil(root:match("vibing%.nvim"))
      end
    end)
  end)

  describe("get_relative_path", function()
    -- These tests use the actual git repository (vibing.nvim)
    local git_root

    before_each(function()
      git_root = Git.get_root()
    end)

    it("should return '.' when given git root itself", function()
      if not git_root then
        pending("Not in git repository")
        return
      end
      local result = Git.get_relative_path(git_root)
      assert.equals(".", result)
    end)

    it("should return '.' when given git root with trailing slash", function()
      if not git_root then
        pending("Not in git repository")
        return
      end
      local result = Git.get_relative_path(git_root .. "/")
      assert.equals(".", result)
    end)

    it("should return directory name for existing subdirectory", function()
      if not git_root then
        pending("Not in git repository")
        return
      end
      -- Use actual directory that exists in vibing.nvim: lua
      local result = Git.get_relative_path(git_root .. "/lua")
      assert.equals("lua", result)
    end)

    it("should return nested path for existing nested directory", function()
      if not git_root then
        pending("Not in git repository")
        return
      end
      -- Use actual nested directory: lua/vibing
      local result = Git.get_relative_path(git_root .. "/lua/vibing")
      assert.equals("lua/vibing", result)
    end)

    it("should return nested path for deeply nested directory", function()
      if not git_root then
        pending("Not in git repository")
        return
      end
      -- Use actual deeply nested directory: lua/vibing/core/utils
      local result = Git.get_relative_path(git_root .. "/lua/vibing/core/utils")
      assert.equals("lua/vibing/core/utils", result)
    end)

    it("should return nil for path outside git root", function()
      if not git_root then
        pending("Not in git repository")
        return
      end
      -- Path that doesn't start with git_root
      local result = Git.get_relative_path("/tmp/other")
      assert.is_nil(result)
    end)

    it("should return nil for similar path like /repo-other (boundary check)", function()
      if not git_root then
        pending("Not in git repository")
        return
      end
      -- This is the critical security test case from code review
      -- If git_root is /home/user/vibing.nvim, this tests /home/user/vibing.nvim-other
      local similar_path = git_root .. "-other"
      local result = Git.get_relative_path(similar_path)
      assert.is_nil(result)
    end)

    it("should return nil for similar path with suffix (boundary check)", function()
      if not git_root then
        pending("Not in git repository")
        return
      end
      -- If git_root is /home/user/vibing.nvim, this tests /home/user/vibing.nvim2
      local similar_path = git_root .. "2"
      local result = Git.get_relative_path(similar_path)
      assert.is_nil(result)
    end)

    it("should handle paths with special characters", function()
      if not git_root then
        pending("Not in git repository")
        return
      end
      -- Test with hypothetical path containing spaces (doesn't need to exist)
      -- We're testing path parsing, not file existence
      local path_with_space = git_root .. "/dir with space"
      local result = Git.get_relative_path(path_with_space)
      -- Should return the relative path regardless of whether it exists
      assert.equals("dir with space", result)
    end)
  end)

  describe("resolve_working_dir", function()
    -- These tests use the actual git repository (vibing.nvim)
    local git_root

    before_each(function()
      git_root = Git.get_root()
    end)

    it("should return git root when working_dir is '.'", function()
      if not git_root then
        pending("Not in git repository")
        return
      end
      local result = Git.resolve_working_dir(".")
      assert.equals(git_root, result)
    end)

    it("should return absolute path for existing directory", function()
      if not git_root then
        pending("Not in git repository")
        return
      end
      -- Use actual directory that exists: lua
      local result = Git.resolve_working_dir("lua")
      assert.equals(git_root .. "/lua", result)
    end)

    it("should return absolute path for nested directory", function()
      if not git_root then
        pending("Not in git repository")
        return
      end
      -- Use actual nested directory: lua/vibing
      local result = Git.resolve_working_dir("lua/vibing")
      assert.equals(git_root .. "/lua/vibing", result)
    end)

    it("should return nil for empty string", function()
      local result = Git.resolve_working_dir("")
      assert.is_nil(result)
    end)

    it("should return nil for nil", function()
      local result = Git.resolve_working_dir(nil)
      assert.is_nil(result)
    end)

    it("should return nil for '~'", function()
      local result = Git.resolve_working_dir("~")
      assert.is_nil(result)
    end)

    it("should return absolute path even for non-existent directory", function()
      if not git_root then
        pending("Not in git repository")
        return
      end
      -- This function doesn't check if directory exists, just builds the path
      local result = Git.resolve_working_dir("nonexistent/dir")
      assert.equals(git_root .. "/nonexistent/dir", result)
    end)
  end)

  describe("is_git_repo", function()
    it("should return boolean", function()
      local result = Git.is_git_repo()
      assert.is_boolean(result)
    end)

    it("should return true when in git repository", function()
      -- This test assumes running in vibing.nvim git repo
      local result = Git.is_git_repo()
      assert.is_true(result)
    end)
  end)
end)
