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
end)
