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

    it("should resolve root against a given cwd, not Neovim's own cwd", function()
      local default_root = Git.get_root()
      if not default_root then
        pending("Not in git repository")
        return
      end
      -- Passing a subdirectory as cwd should resolve to the same git root
      local result = Git.get_root(default_root .. "/lua")
      assert.equals(default_root, result)
    end)

    it("should return nil instead of erroring when cwd does not exist", function()
      -- Regression test: vim.system with a non-existent cwd raises at the
      -- uv_spawn level, so get_root must not propagate that as a Lua error
      -- (e.g. a stale worktree path in a chat's working_dir frontmatter).
      local ok, result = pcall(Git.get_root, "/nonexistent/path/for/vibing-nvim-tests")
      assert.is_true(ok)
      assert.is_nil(result)
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

  describe("resolve_working_dir path boundary", function()
    -- A fixture tree stands in for the git root so symlinks can be created without
    -- touching the real repository. `git rev-parse --show-toplevel` always reports the
    -- physical path, so the stub resolves the tempdir the same way (on macOS
    -- vim.fn.tempname() lives under the /tmp -> /private/tmp symlink).
    local Fs = require("vibing.core.utils.fs")
    local root, outside, real_get_root, notifications

    before_each(function()
      local base = vim.fn.resolve(vim.fn.tempname())
      root = base .. "/repo"
      outside = base .. "/outside"
      Fs.ensure_dir(root .. "/sub")
      Fs.ensure_dir(outside)
      assert(vim.uv.fs_symlink(root .. "/sub", root .. "/link_inside"))
      assert(vim.uv.fs_symlink(outside, root .. "/link_outside"))

      real_get_root = Git.get_root
      Git.get_root = function()
        return root
      end

      -- Notify holds warn_once's memo table, so reloading it between tests is what makes each
      -- rejection warn again
      package.loaded["vibing.core.utils.notify"] = nil
      notifications = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      require("vibing.core.utils.notify").notify = function(message)
        table.insert(notifications, message)
      end
    end)

    after_each(function()
      Git.get_root = real_get_root
      package.loaded["vibing.core.utils.notify"] = nil
    end)

    it("allows a directory inside the git root", function()
      assert.equals(root .. "/sub", Git.resolve_working_dir("sub"))
      assert.same({}, notifications)
    end)

    it("allows the git root itself reached through '..'", function()
      -- The boundary itself is inside, not outside
      assert.equals(root .. "/sub/..", Git.resolve_working_dir("sub/.."))
      assert.same({}, notifications)
    end)

    it("rejects a path that escapes the git root with '..'", function()
      assert.is_nil(Git.resolve_working_dir("../outside"))
      assert.is_nil(Git.resolve_working_dir("../.."))
    end)

    it("rejects a sibling directory whose name merely shares the root's prefix", function()
      -- "<root>-evil" starts with the root string but is not under it
      assert.is_nil(Git.resolve_working_dir("../repo-evil"))
    end)

    it("follows symlinks: one pointing inside the root is allowed", function()
      assert.equals(root .. "/link_inside", Git.resolve_working_dir("link_inside"))
      assert.same({}, notifications)
    end)

    it("follows symlinks: one pointing outside the root is rejected", function()
      -- A pure string comparison would accept this, since the literal path is under the root
      assert.is_nil(Git.resolve_working_dir("link_outside"))
    end)

    it("rejects a '..' that climbs out through a symlink", function()
      -- link_inside resolves to <root>/sub, so this lands on <root>/../outside
      assert.is_nil(Git.resolve_working_dir("link_inside/../../outside"))
    end)

    it("warns once per rejected working_dir instead of on every call", function()
      Git.resolve_working_dir("../outside")
      Git.resolve_working_dir("../outside")
      Git.resolve_working_dir("../outside")
      assert.equals(1, #notifications)
      assert.is_truthy(notifications[1]:find("../outside", 1, true))

      Git.resolve_working_dir("../..")
      assert.equals(2, #notifications)
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
