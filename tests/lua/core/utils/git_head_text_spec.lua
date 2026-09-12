-- git_head_text.lua は、そのターンのpatchが無かったときに `gd` が使う参照テキスト。
-- 「HEADに無い」は失敗ではなく **空テーブル**（＝そのファイル全体が新規）で、この区別が
-- 崩れるとフォールバックがフォールバックできなくなる。
local GitHeadText = require("vibing.core.utils.git_head_text")

describe("git_head_text.lines", function()
  local repo_dir

  local function write_file(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
  end

  local function git(args)
    local cmd = { "git" }
    vim.list_extend(cmd, args)
    local result = vim.system(cmd, { cwd = repo_dir, text = true }):wait()
    assert.equals(0, result.code, result.stderr)
  end

  before_each(function()
    repo_dir = vim.fn.tempname()
    vim.fn.mkdir(repo_dir, "p")
    repo_dir = vim.fn.fnamemodify(repo_dir, ":p"):gsub("/$", "")
    git({ "init", "-q" })
    git({ "config", "user.email", "test@example.com" })
    git({ "config", "user.name", "test" })
  end)

  after_each(function()
    vim.fn.delete(repo_dir, "rf")
  end)

  it("returns the committed content, not what is on disk now", function()
    local file = repo_dir .. "/tracked.txt"
    write_file(file, "one\ntwo\n")
    git({ "add", "." })
    git({ "commit", "-q", "-m", "init" })
    write_file(file, "one\nedited\nthree\n")

    assert.same({ "one", "two" }, GitHeadText.lines(file))
  end)

  it("keeps a file with no trailing newline to its real line count", function()
    local file = repo_dir .. "/no_newline.txt"
    write_file(file, "only line")
    git({ "add", "." })
    git({ "commit", "-q", "-m", "init" })

    assert.same({ "only line" }, GitHeadText.lines(file))
  end)

  it("is empty for a file HEAD does not have", function()
    local file = repo_dir .. "/untracked.txt"
    write_file(file, "brand new\n")
    git({ "commit", "-q", "--allow-empty", "-m", "init" })

    assert.same({}, GitHeadText.lines(file))
  end)

  it("is empty in a repository with no commits at all", function()
    local file = repo_dir .. "/staged.txt"
    write_file(file, "staged\n")
    git({ "add", "." })

    assert.same({}, GitHeadText.lines(file))
  end)

  it("is empty outside a git repository", function()
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    local file = outside .. "/loose.txt"
    write_file(file, "loose\n")

    local lines = GitHeadText.lines(file)
    vim.fn.delete(outside, "rf")

    assert.same({}, lines)
  end)

  it("is empty for a path that does not exist", function()
    assert.same({}, GitHeadText.lines("/nope/does/not/exist.txt"))
  end)
end)
