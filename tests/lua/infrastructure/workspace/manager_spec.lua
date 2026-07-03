-- tests/lua/infrastructure/workspace/manager_spec.lua
local Manager = require("vibing.infrastructure.workspace.manager")

local function init_tmp_git_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function run(cmd)
    vim.fn.system(string.format("git -C %s %s", vim.fn.shellescape(dir), cmd))
  end
  run("init -q")
  run("config user.email test@example.com")
  run("config user.name test")
  vim.fn.writefile({ "hello" }, dir .. "/README.md")
  run("add README.md")
  run("commit -q -m init")
  return dir
end

describe("vibing.infrastructure.workspace.manager", function()
  local repo
  local prev_cwd

  before_each(function()
    repo = init_tmp_git_repo()
    prev_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
  end)

  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(prev_cwd))
    vim.fn.delete(repo, "rf")
  end)

  describe("create", function()
    it("creates workspace directory, meta.yaml, plan.md and a git worktree", function()
      local ws, err = Manager.create("fix-auth-session-bug", "auth session bug fix")
      assert.is_nil(err)
      assert.equals("0001-fix-auth-session-bug", ws.id)
      assert.equals(1, vim.fn.isdirectory(ws.dir))
      assert.equals(1, vim.fn.isdirectory(ws.worktree_path))
      assert.equals(1, vim.fn.filereadable(ws.meta_path))
      assert.equals(1, vim.fn.filereadable(ws.plan_path))

      local branches = vim.fn.systemlist("git branch --list fix-auth-session-bug")
      assert.equals(1, #branches)
    end)

    it("increments the workspace id on each call", function()
      local ws1 = Manager.create("first-task", "first")
      local ws2 = Manager.create("second-task", "second")
      assert.equals("0001-first-task", ws1.id)
      assert.equals("0002-second-task", ws2.id)
    end)

    it("rejects a branch name containing a path separator", function()
      local ws, err = Manager.create("feature/nested", "nested")
      assert.is_nil(ws)
      assert.is_not_nil(err)
    end)
  end)

  describe("list", function()
    it("lists only active workspaces by default content", function()
      Manager.create("task-a", "Task A")
      Manager.create("task-b", "Task B")

      local active = Manager.list("active")
      assert.equals(2, #active)

      local done = Manager.list("done")
      assert.equals(0, #done)
    end)
  end)

  describe("get", function()
    it("finds an active workspace by id", function()
      local ws = Manager.create("task-a", "Task A")
      local found = Manager.get(ws.id)
      assert.is_not_nil(found)
      assert.equals("active", found.status)
      assert.equals(ws.worktree_path, found.worktree_path)
    end)

    it("returns nil for unknown id", function()
      assert.is_nil(Manager.get("9999-does-not-exist"))
    end)
  end)

  describe("remove_worktree + move_to_done", function()
    it("removes the git worktree and moves the workspace dir to done", function()
      local ws = Manager.create("task-a", "Task A")

      local ok, err = Manager.remove_worktree(ws.id)
      assert.is_true(ok, err)
      assert.equals(0, vim.fn.isdirectory(ws.worktree_path))

      local moved, move_err = Manager.move_to_done(ws.id)
      assert.is_true(moved, move_err)

      assert.is_nil(Manager.get(ws.id).worktree_path)
      assert.equals("done", Manager.get(ws.id).status)
      assert.equals(0, #Manager.list("active"))
      assert.equals(1, #Manager.list("done"))
    end)

    it("fails to remove worktree when there are uncommitted changes", function()
      local ws = Manager.create("task-a", "Task A")
      vim.fn.writefile({ "dirty" }, ws.worktree_path .. "/dirty.txt")

      local ok, err = Manager.remove_worktree(ws.id)
      assert.is_false(ok)
      assert.is_not_nil(err)
      assert.equals(1, vim.fn.isdirectory(ws.worktree_path))
    end)
  end)

  describe("plan_has_incomplete_todos", function()
    it("returns true when plan.md has an unchecked item", function()
      local ws = Manager.create("task-a", "Task A")
      assert.is_true(Manager.plan_has_incomplete_todos(ws.plan_path))
    end)

    it("returns false once all items are checked", function()
      local ws = Manager.create("task-a", "Task A")
      vim.fn.writefile({ "# Task A", "", "## TODO", "", "- [x] done item", "", "## Notes" }, ws.plan_path)
      assert.is_false(Manager.plan_has_incomplete_todos(ws.plan_path))
    end)
  end)
end)
