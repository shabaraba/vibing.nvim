local Context = require("vibing.core.utils.mote.context")

describe("mote context", function()
  describe("build_name", function()
    it("returns a worktree-scoped name for a cwd under .vibing/worktrees/<branch>", function()
      local name = Context.build_name("vibing", "/repo/.vibing/worktrees/fix-auth-session-bug")
      assert.is_true(name:match("^vibing%-worktree%-fix%-auth%-session%-bug%-%x%x%x%x%x%x%x%x$") ~= nil)
    end)

    it("is stable for the same branch name", function()
      local first = Context.build_name("vibing", "/repo/.vibing/worktrees/my-branch")
      local second = Context.build_name("vibing", "/repo/.vibing/worktrees/my-branch")
      assert.equals(first, second)
    end)

    it("falls back to <prefix>-root when cwd is not under .vibing/worktrees/", function()
      assert.equals("vibing-root", Context.build_name("vibing", "/repo"))
    end)

    it("falls back to <prefix>-root when cwd is nil", function()
      assert.equals("vibing-root", Context.build_name("vibing", nil))
    end)
  end)

  describe("cwd resolution against a foreign git repository", function()
    local Git = require("vibing.core.utils.git")
    local tmp_dir
    local resolved_root

    before_each(function()
      tmp_dir = vim.fn.tempname()
      vim.fn.mkdir(tmp_dir, "p")
      vim.system({ "git", "init" }, { cwd = tmp_dir }):wait()
      -- git rev-parse resolves symlinks (e.g. macOS /tmp -> /private/tmp),
      -- so compare against Git.get_root's own resolution rather than tmp_dir itself.
      resolved_root = Git.get_root(tmp_dir)
    end)

    after_each(function()
      vim.fn.delete(tmp_dir, "rf")
    end)

    it("get_project_name resolves against the given cwd's repo, not Neovim's own cwd", function()
      local expected = vim.fn.fnamemodify(resolved_root, ":t"):gsub("[^%w%-_]+", "-")
      assert.equals(expected, Context.get_project_name(tmp_dir))
    end)

    it("build_dir_path is rooted under the given cwd's repo, not Neovim's own cwd", function()
      local result = Context.build_dir_path("myproject", "myctx", tmp_dir)
      assert.equals(resolved_root .. "/.vibing/mote/myproject/myctx", result)
    end)
  end)
end)
