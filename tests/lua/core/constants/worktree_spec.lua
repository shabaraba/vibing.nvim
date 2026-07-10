local Worktree = require("vibing.core.constants.worktree")

describe("worktree constants", function()
  describe("match_branch", function()
    it("extracts the branch name from a cwd under the worktree directory", function()
      assert.equals("fix-auth-session-bug", Worktree.match_branch("/repo/.vibing/worktrees/fix-auth-session-bug"))
    end)

    it("returns nil for a cwd outside the worktree directory", function()
      assert.is_nil(Worktree.match_branch("/repo"))
    end)

    it("returns nil for a nil cwd", function()
      assert.is_nil(Worktree.match_branch(nil))
    end)
  end)
end)
