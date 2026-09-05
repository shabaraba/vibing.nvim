-- Tests for the `chat_conflicts` RPC method backing the nvim_chat_conflicts MCP tool (#699).
--
-- #692's postmortem: two PRs each changed the same header-parsing assumption on their own
-- worktree/branch, and the collision was only caught because a human happened to be looking at
-- both diffs at once. `chat_conflicts` does that comparison mechanically -- for every live chat
-- with its own `working_dir`, diff its worktree against main/master and group the touched files
-- across chats, warning (never blocking) about any file 2+ chats touched.
--
-- Real git worktrees are required to exercise the actual `git diff --name-only` call, so this
-- spec builds a real repository in a temp directory, the same way git_snapshot_spec.lua does.

local ChatBuffers = require("tests.helpers.chat_buffers")
local Git = require("vibing.core.utils.git")

describe("rpc handlers: chat_conflicts", function()
  local handler
  local repo
  local real_get_root

  local function git_ok(args, cwd)
    local cmd = { "git" }
    vim.list_extend(cmd, args)
    local result = vim.system(cmd, { cwd = cwd or repo, text = true }):wait()
    assert.equals(0, result.code, table.concat(args, " ") .. ": " .. tostring(result.stderr))
    return vim.trim(result.stdout or "")
  end

  local function write(path, content)
    local dir = vim.fn.fnamemodify(path, ":h")
    vim.fn.mkdir(dir, "p")
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
  end

  ---mainからブランチしたworktreeを作り、指定ファイルを1コミットで変更する
  ---@param name string worktreeディレクトリ名（= git_rootからの相対working_dir）
  ---@param file string
  ---@param content string
  local function add_worktree(name, file, content)
    git_ok({ "worktree", "add", "-b", name, name }, repo)
    write(repo .. "/" .. name .. "/" .. file, content)
    git_ok({ "add", "." }, repo .. "/" .. name)
    git_ok({ "commit", "-q", "-m", "change " .. file }, repo .. "/" .. name)
  end

  before_each(function()
    ChatBuffers.setup()
    handler = require("vibing.infrastructure.rpc.handlers.chat")

    repo = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(repo, "p")
    git_ok({ "init", "-q", "-b", "main" }, repo)
    git_ok({ "config", "user.email", "test@example.com" }, repo)
    git_ok({ "config", "user.name", "test" }, repo)
    write(repo .. "/tracked.txt", "before\n")
    git_ok({ "add", "." }, repo)
    git_ok({ "commit", "-q", "-m", "init" }, repo)

    real_get_root = Git.get_root
    Git.get_root = function()
      return repo
    end
  end)

  after_each(function()
    Git.get_root = real_get_root
    ChatBuffers.reset()
    if repo then
      vim.fn.delete(repo, "rf")
    end
  end)

  local function find_conflict(conflicts, file)
    for _, conflict in ipairs(conflicts) do
      if conflict.file == file then
        return conflict
      end
    end
    return nil
  end

  local function has_bufnr(chats, bufnr)
    for _, chat in ipairs(chats) do
      if chat.bufnr == bufnr then
        return true
      end
    end
    return false
  end

  it("returns no conflicts when no chat is open", function()
    local result = handler.chat_conflicts({})

    assert.same({}, result.conflicts)
  end)

  it("returns no conflicts for a single chat on its own worktree", function()
    add_worktree("branchA", "shared.txt", "from A\n")
    handler.create_chat({ working_dir = "branchA" })

    local result = handler.chat_conflicts({})

    assert.same({}, result.conflicts)
  end)

  it("ignores a chat with no working_dir of its own", function()
    handler.create_chat({})

    local result = handler.chat_conflicts({})

    assert.same({}, result.conflicts)
  end)

  it("reports a file touched by two chats on separate worktrees", function()
    add_worktree("branchA", "shared.txt", "from A\n")
    add_worktree("branchB", "shared.txt", "from B\n")
    local chatA = handler.create_chat({ working_dir = "branchA" })
    local chatB = handler.create_chat({ working_dir = "branchB" })

    local result = handler.chat_conflicts({})

    assert.equals("main", result.base)
    assert.same({}, result.skipped)
    assert.equals(1, #result.conflicts)
    local conflict = find_conflict(result.conflicts, "shared.txt")
    assert.is_not_nil(conflict)
    assert.equals(2, #conflict.chats)
    assert.is_true(has_bufnr(conflict.chats, chatA.bufnr))
    assert.is_true(has_bufnr(conflict.chats, chatB.bufnr))
  end)

  it("does not report a file only one chat touched", function()
    add_worktree("branchA", "shared.txt", "from A\n")
    add_worktree("branchC", "solo.txt", "only C\n")
    handler.create_chat({ working_dir = "branchA" })
    handler.create_chat({ working_dir = "branchC" })

    local result = handler.chat_conflicts({})

    assert.same({}, result.conflicts)
  end)

  it("projects each contributing chat's task from its orchestrator (#696 follow-up)", function()
    add_worktree("branchA", "shared.txt", "from A\n")
    add_worktree("branchB", "shared.txt", "from B\n")
    local orchestrator = handler.create_chat({})
    local chatA = handler.create_chat({
      working_dir = "branchA",
      from_bufnr = orchestrator.bufnr,
      task = "PR #686 -- fix parsing",
    })
    local chatB = handler.create_chat({
      working_dir = "branchB",
      from_bufnr = orchestrator.bufnr,
      task = "PR #688 -- review fixes",
    })

    local result = handler.chat_conflicts({})

    local conflict = find_conflict(result.conflicts, "shared.txt")
    assert.is_not_nil(conflict)
    for _, chat in ipairs(conflict.chats) do
      if chat.bufnr == chatA.bufnr then
        assert.equals("PR #686 -- fix parsing", chat.task)
      elseif chat.bufnr == chatB.bufnr then
        assert.equals("PR #688 -- review fixes", chat.task)
      end
    end
  end)

  it("lists a chat whose worktree git cannot diff under skipped, with git's reason", function()
    -- An orphan branch has no merge base with main, so `main...HEAD` fails. Dropping that chat
    -- silently would leave `conflicts = {}` reading as "nothing collides" -- the one answer this
    -- tool must never give by accident.
    add_worktree("branchA", "shared.txt", "from A\n")
    git_ok({ "worktree", "add", "--detach", "orphaned" }, repo)
    git_ok({ "checkout", "-q", "--orphan", "unrelated" }, repo .. "/orphaned")
    write(repo .. "/orphaned/only.txt", "x\n")
    git_ok({ "add", "." }, repo .. "/orphaned")
    git_ok({ "commit", "-q", "-m", "orphan" }, repo .. "/orphaned")
    handler.create_chat({ working_dir = "branchA" })
    local orphan = handler.create_chat({ working_dir = "orphaned" })

    local result = handler.chat_conflicts({})

    assert.same({}, result.conflicts)
    assert.equals(1, #result.skipped)
    assert.equals(orphan.bufnr, result.skipped[1].bufnr)
    assert.equals("orphaned", result.skipped[1].working_dir)
    assert.is_truthy(result.skipped[1].reason:find("no merge base", 1, true))
  end)

  it("warns instead of returning a bare empty list when there is no base branch to diff against", function()
    -- resolve_base_branch finds nothing to diff against; the handler degrades rather than
    -- erroring, consistent with #699 being warn-only -- but says so, since an empty `conflicts`
    -- would otherwise read as "nothing collides".
    git_ok({ "branch", "-m", "main", "trunk" }, repo)

    local result = handler.chat_conflicts({})

    assert.same({}, result.conflicts)
    assert.is_nil(result.base)
    assert.is_truthy(result.warning:find("main", 1, true))
  end)

  it("warns when the instance is not inside a git repository at all", function()
    Git.get_root = function()
      return nil
    end

    local result = handler.chat_conflicts({})

    assert.same({}, result.conflicts)
    assert.is_truthy(result.warning:find("git repository", 1, true))
  end)
end)
