-- patch_text.lua は「ターンのpatchから、そのターンが始まる前のファイル内容を復元する」モジュール。
-- mini.diff の参照テキストがこれで作られるので、守りたいのは3つ:
--   1. 復元した内容が本当にターン前のものであること — 本題
--   2. 実ワーキングツリーを1バイトも書き換えないこと（revertと違って「読むだけ」）
--   3. 復元できない場合に、黙って嘘の内容を返すのではなくエラーを返すこと
-- patchは実物のgitで作り、逆適用も実物のgitにやらせる。
local PatchText = require("vibing.core.utils.patch_text")

describe("patch_text", function()
  local repo

  local function git(args)
    return vim.system(vim.list_extend({ "git" }, args), { cwd = repo, text = true }):wait()
  end

  local function write(rel, lines)
    local path = repo .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
  end

  local function read(rel)
    return vim.fn.readfile(repo .. "/" .. rel)
  end

  ---base commit と現在のワーキングツリーの差分を、vibing形式のpatch本文として得る
  ---
  ---`git diff <base>` ではなく一時indexへ `git add -A` してからツリー同士を比較するのは、
  ---production（`git_snapshot.lua`）がそうしているから。素の `git diff` は未追跡ファイルを
  ---出さないので、「ターンが新規作成したファイル」のケースが再現できない。
  local function patch_for(base)
    local tmp_index = vim.fn.tempname()
    local env = { GIT_INDEX_FILE = tmp_index }

    vim.system({ "git", "add", "-A", "--", "." }, { cwd = repo, env = env, text = true }):wait()
    local tree_result = vim.system({ "git", "write-tree" }, { cwd = repo, env = env, text = true }):wait()
    local tree = vim.trim(tree_result.stdout or "")

    local result = vim.system({ "git", "diff", "--binary", base, tree, "--", "." }, { cwd = repo, text = true }):wait()
    vim.fn.delete(tmp_index)

    assert.equals(0, result.code)
    return result.stdout
  end

  before_each(function()
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    git({ "init", "-q" })
    git({ "config", "user.email", "t@example.com" })
    git({ "config", "user.name", "t" })
  end)

  after_each(function()
    vim.fn.delete(repo, "rf")
  end)

  it("returns the pre-turn content of a modified file", function()
    write("src/a.txt", { "one", "two", "three" })
    git({ "add", "-A" })
    git({ "commit", "-qm", "base" })
    local base = vim.trim(git({ "rev-parse", "HEAD" }).stdout)

    write("src/a.txt", { "one", "TWO CHANGED", "three", "four" })
    local file_diff = patch_for(base)

    local before, err = PatchText.before_lines(repo, "src/a.txt", file_diff)
    assert.is_nil(err)
    assert.same({ "one", "two", "three" }, before)
  end)

  it("leaves the working tree untouched", function()
    write("a.txt", { "original" })
    git({ "add", "-A" })
    git({ "commit", "-qm", "base" })
    local base = vim.trim(git({ "rev-parse", "HEAD" }).stdout)

    write("a.txt", { "edited by the agent" })
    local file_diff = patch_for(base)

    PatchText.before_lines(repo, "a.txt", file_diff)

    -- 復元は一時ツリーで行われるので、実ファイルはターン後の内容のまま
    assert.same({ "edited by the agent" }, read("a.txt"))
    -- indexも動かない（`git diff --cached` が空のまま）
    assert.equals("", vim.trim(git({ "diff", "--cached", "--name-only" }).stdout))
  end)

  it("returns an empty reference for a file the turn created", function()
    write("keep.txt", { "x" })
    git({ "add", "-A" })
    git({ "commit", "-qm", "base" })
    local base = vim.trim(git({ "rev-parse", "HEAD" }).stdout)

    write("new.txt", { "brand new" })
    local file_diff = patch_for(base)

    local before, err = PatchText.before_lines(repo, "new.txt", file_diff)
    assert.is_nil(err)
    -- nil（失敗）ではなく空テーブル。mini.diff はこれをバッファ全体1つの "add" hunk として描く
    assert.same({}, before)
  end)

  it("refuses a binary diff instead of returning garbled lines", function()
    write("bin.dat", { "placeholder" })
    git({ "add", "-A" })
    git({ "commit", "-qm", "base" })
    local base = vim.trim(git({ "rev-parse", "HEAD" }).stdout)

    local f = assert(io.open(repo .. "/bin.dat", "wb"))
    f:write("\0\1\2\3binary\0content")
    f:close()
    local file_diff = patch_for(base)

    local before, err = PatchText.before_lines(repo, "bin.dat", file_diff)
    assert.is_nil(before)
    assert.is_truthy(err and err:match("binary"))
  end)

  it("fails rather than guessing when the file changed after the turn", function()
    write("a.txt", { "one", "two", "three" })
    git({ "add", "-A" })
    git({ "commit", "-qm", "base" })
    local base = vim.trim(git({ "rev-parse", "HEAD" }).stdout)

    write("a.txt", { "one", "TWO CHANGED", "three" })
    local file_diff = patch_for(base)

    -- ターン後にユーザーが手で書き換えた: patchのコンテキストがもう合わない
    write("a.txt", { "completely", "different", "content", "now" })

    local before, err = PatchText.before_lines(repo, "a.txt", file_diff)
    assert.is_nil(before)
    assert.is_truthy(err)
  end)

  it("reports a missing file instead of erroring", function()
    local before, err = PatchText.before_lines(repo, "nope.txt", "diff --git a/nope.txt b/nope.txt\n")
    assert.is_nil(before)
    assert.is_truthy(err and err:match("not readable"))
  end)
end)
