-- git_snapshot.lua は「リクエスト前後のワーキングツリーをgitツリーオブジェクトとして固め、
-- その差分をpatchにする」モジュール。ここで守りたいのは主に3つ:
--   1. Bash相当（ツールイベントを一切伴わないファイル操作）の変更が patch に出ること — 本題
--   2. ユーザーのindexとワーキングツリーに触らないこと
--   3. 生成したpatchが `git apply --reverse` で本当に戻せること
-- そのため各ケースは実物のgitリポジトリを一時ディレクトリに作り、実際にgitを呼ぶ。
local GitSnapshot = require("vibing.core.utils.git_snapshot")

describe("git_snapshot", function()
  local repo
  local handle_seq = 0

  local function git(args, cwd)
    local cmd = { "git" }
    vim.list_extend(cmd, args)
    local result = vim.system(cmd, { cwd = cwd or repo, text = true }):wait()
    return result
  end

  local function git_ok(args, cwd)
    local result = git(args, cwd)
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

  local function read(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local content = f:read("*a")
    f:close()
    return content
  end

  ---毎回新しいhandle_idを配る（refもセッション状態もこれで分かれる）
  local function next_handle()
    handle_seq = handle_seq + 1
    return "handle" .. tostring(handle_seq)
  end

  ---ベースライン取得 → mutate() → 差分生成、をまとめて回す
  ---@param mutate fun()
  ---@param extra_paths table<string, boolean>|nil
  local function run_turn(mutate, extra_paths)
    local handle = next_handle()
    GitSnapshot.ensure_baseline(handle, repo, "Bash")
    mutate()
    local files, abs_files, patch = GitSnapshot.generate(handle, extra_paths)
    return { handle = handle, files = files, abs_files = abs_files, patch = patch }
  end

  local function init_repo(opts)
    opts = opts or {}
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    -- macOSの /var → /private/var のように、tempnameがシンボリックリンク越しのことがある。
    -- git は常に実体パスを返すので、比較の基準を最初から実体パスに揃えておく
    repo = vim.fn.resolve(repo)
    git_ok({ "init", "-q" })
    git_ok({ "config", "user.email", "test@example.com" })
    git_ok({ "config", "user.name", "test" })
    if not opts.unborn then
      write(repo .. "/tracked.txt", "before\n")
      write(repo .. "/.gitignore", "ignored/\n*.log\n")
      git_ok({ "add", "." })
      git_ok({ "commit", "-q", "-m", "init" })
    end
  end

  before_each(function()
    GitSnapshot._reset()
    init_repo()
  end)

  after_each(function()
    GitSnapshot._reset()
    if repo then
      vim.fn.delete(repo, "rf")
    end
  end)

  describe("is_available", function()
    it("is true inside a repository and false outside one", function()
      assert.is_true(GitSnapshot.is_available(repo))

      local outside = vim.fn.tempname()
      vim.fn.mkdir(outside, "p")
      assert.is_false(GitSnapshot.is_available(outside))
      vim.fn.delete(outside, "rf")
    end)

    it("normalizes a subdirectory to the worktree root", function()
      vim.fn.mkdir(repo .. "/nested/deep", "p")

      assert.equals(repo, GitSnapshot.worktree_root(repo .. "/nested/deep"))
    end)
  end)

  describe("ensure_baseline", function()
    it("skips tools that cannot change a file", function()
      local handle = next_handle()
      GitSnapshot.ensure_baseline(handle, repo, "Read")

      assert.is_false(GitSnapshot.has_baseline(handle))
    end)

    it("treats an unknown tool name as one that could write", function()
      -- MCPツールのように性質が名前から分からないものは変更しうる側に倒す
      local handle = next_handle()
      GitSnapshot.ensure_baseline(handle, repo, "mcp__something__unknown_tool")

      assert.is_true(GitSnapshot.has_baseline(handle))
    end)

    it("is a no-op on the second call in the same request", function()
      local handle = next_handle()
      GitSnapshot.ensure_baseline(handle, repo, "Bash")
      local first = git_ok({ "rev-parse", GitSnapshot._REF_PREFIX .. handle })

      write(repo .. "/tracked.txt", "changed in between\n")
      GitSnapshot.ensure_baseline(handle, repo, "Write")

      assert.equals(first, git_ok({ "rev-parse", GitSnapshot._REF_PREFIX .. handle }))
    end)

    it("takes no baseline outside a git repository", function()
      local outside = vim.fn.tempname()
      vim.fn.mkdir(outside, "p")
      local handle = next_handle()

      GitSnapshot.ensure_baseline(handle, outside, "Bash")

      assert.is_false(GitSnapshot.has_baseline(handle))
      vim.fn.delete(outside, "rf")
    end)
  end)

  describe("generate", function()
    it("captures an edit to a tracked file", function()
      local turn = run_turn(function()
        write(repo .. "/tracked.txt", "after\n")
      end)

      assert.same({ "tracked.txt" }, turn.files)
      assert.same({ repo .. "/tracked.txt" }, turn.abs_files)
      assert.is_truthy(turn.patch:find("-before", 1, true))
      assert.is_truthy(turn.patch:find("+after", 1, true))
    end)

    it("captures a change no tool event ever reported (the Bash case)", function()
      -- これがこのモジュールの存在理由。extra_paths を一切渡さず、ツール引数にも現れない
      -- 変更が patch に出ることを見る
      local turn = run_turn(function()
        local result = vim.system({ "sh", "-c", "printf 'rewritten\\n' > tracked.txt" }, { cwd = repo }):wait()
        assert.equals(0, result.code)
      end)

      assert.same({ "tracked.txt" }, turn.files)
      assert.is_truthy(turn.patch:find("+rewritten", 1, true))
    end)

    it("shows a new file as a diff from /dev/null", function()
      local turn = run_turn(function()
        write(repo .. "/added.txt", "fresh\n")
      end)

      assert.same({ "added.txt" }, turn.files)
      assert.is_truthy(turn.patch:find("--- /dev/null", 1, true))
      assert.is_truthy(turn.patch:find("+++ b/added.txt", 1, true))
    end)

    it("shows a deleted file as a diff to /dev/null", function()
      local turn = run_turn(function()
        vim.fn.delete(repo .. "/tracked.txt")
      end)

      assert.same({ "tracked.txt" }, turn.files)
      assert.is_truthy(turn.patch:find("--- a/tracked.txt", 1, true))
      assert.is_truthy(turn.patch:find("+++ /dev/null", 1, true))
    end)

    it("leaves .gitignore'd changes out of the patch", function()
      local turn = run_turn(function()
        write(repo .. "/build.log", "noise\n")
        write(repo .. "/ignored/artifact.bin", "noise\n")
      end)

      assert.same({}, turn.files)
      assert.is_nil(turn.patch)
    end)

    it("ignores vibing.nvim's own state directory even when it is not gitignored", function()
      -- .vibing/ にはチャットファイルとpatchが入り、ターン中にも書き換わる。gitignoreしていない
      -- ユーザーでも会話ログ自身がdiffに載らないこと
      local turn = run_turn(function()
        write(repo .. "/.vibing/chat/2026-01-01.md", "## User\nhello\n")
        write(repo .. "/tracked.txt", "after\n")
      end)

      assert.same({ "tracked.txt" }, turn.files)
      assert.is_nil(turn.patch:find(".vibing", 1, true))
    end)

    it("lists a tool-event path that git does not see, without a patch section", function()
      -- .gitignore対象でもツール引数で分かっている分は一覧には載せる（patchは作らない）
      local turn = run_turn(function()
        write(repo .. "/build.log", "noise\n")
      end, { [repo .. "/build.log"] = true })

      assert.same({ "build.log" }, turn.files)
      assert.is_nil(turn.patch)
    end)

    it("does not list a tool-event path twice when git saw it too", function()
      local turn = run_turn(function()
        write(repo .. "/tracked.txt", "after\n")
      end, { [repo .. "/tracked.txt"] = true })

      assert.same({ "tracked.txt" }, turn.files)
    end)

    it("carries the base header the patch viewer reads", function()
      local turn = run_turn(function()
        write(repo .. "/tracked.txt", "after\n")
      end)

      assert.equals("# vibing-request-diff base: " .. repo, turn.patch:match("^[^\n]+"))
    end)

    it("returns no patch when nothing changed", function()
      local turn = run_turn(function() end)

      assert.same({}, turn.files)
      assert.is_nil(turn.patch)
    end)

    it("works in a repository with no commits at all", function()
      GitSnapshot._reset()
      vim.fn.delete(repo, "rf")
      init_repo({ unborn = true })

      local turn = run_turn(function()
        write(repo .. "/first.txt", "hello\n")
      end)

      assert.same({ "first.txt" }, turn.files)
      assert.is_truthy(turn.patch:find("+hello", 1, true))
    end)
  end)

  describe("the file list", function()
    -- 一覧は `git diff --name-only` に聞いており、patch本文からは抜いていない。ここはその
    -- 判断を固定するためのケース: 下の3種類はpatchに `+++ b/…` 行を **持たない** ので、
    -- 本文をparseする実装だと Modified Files から静かに消える。

    it("lists a binary file, which has no +++ line in the patch", function()
      write(repo .. "/img.bin", "\0\1before")
      git_ok({ "add", "." })
      git_ok({ "commit", "-q", "-m", "add binary" })

      local turn = run_turn(function()
        write(repo .. "/img.bin", "\0\2after")
      end)

      assert.same({ "img.bin" }, turn.files)
      assert.is_truthy(turn.patch:find("GIT binary patch", 1, true))
      assert.is_nil(turn.patch:find("+++ b/img.bin", 1, true))
    end)

    it("lists a pure rename, which has no +++ line in the patch", function()
      write(repo .. "/tomove.txt", "unchanged content\n")
      git_ok({ "add", "." })
      git_ok({ "commit", "-q", "-m", "add file to move" })

      local turn = run_turn(function()
        git_ok({ "mv", "tomove.txt", "moved.txt" })
      end)

      assert.same({ "moved.txt" }, turn.files)
      assert.is_truthy(turn.patch:find("rename to moved.txt", 1, true))
      assert.is_nil(turn.patch:find("+++ b/", 1, true))
    end)

    it("lists a mode-only change, which has no hunk in the patch at all", function()
      write(repo .. "/script.sh", "#!/bin/sh\n")
      git_ok({ "add", "." })
      git_ok({ "commit", "-q", "-m", "add script" })

      local turn = run_turn(function()
        vim.fn.setfperm(repo .. "/script.sh", "rwxr-xr-x")
      end)

      assert.same({ "script.sh" }, turn.files)
      assert.is_truthy(turn.patch:find("new mode 100755", 1, true))
      assert.is_nil(turn.patch:find("@@", 1, true))
    end)

    it("keeps a path containing a space in one piece", function()
      -- `diff --git a/X b/Y` を正規表現で割る実装が壊れる形
      local turn = run_turn(function()
        write(repo .. "/a file.txt", "spaced\n")
      end)

      assert.same({ "a file.txt" }, turn.files)
      assert.same({ repo .. "/a file.txt" }, turn.abs_files)
    end)
  end)

  describe("the patch it writes", function()
    ---patchを書き出して `git apply --reverse` で戻す
    local function reverse_apply(patch)
      local tmp = vim.fn.tempname()
      write(tmp, patch:match("\n$") and patch or (patch .. "\n"))
      local result = git({ "apply", "--reverse", "--whitespace=nowarn", tmp })
      vim.fn.delete(tmp)
      return result
    end

    it("reverses cleanly for a file with no trailing newline", function()
      -- request_diff.lua が git diff --no-index の回避策を必要とした箇所。git本体に任せる分、
      -- ここは `\ No newline at end of file` まで含めて正しく出る
      write(repo .. "/nonewline.txt", "original")
      git_ok({ "add", "." })
      git_ok({ "commit", "-q", "-m", "add nonewline" })

      local turn = run_turn(function()
        write(repo .. "/nonewline.txt", "rewritten")
      end)

      assert.equals(0, reverse_apply(turn.patch).code)
      assert.equals("original", read(repo .. "/nonewline.txt"))
    end)

    it("reverses a new file back out of existence", function()
      local turn = run_turn(function()
        write(repo .. "/added.txt", "fresh\n")
      end)

      assert.equals(0, reverse_apply(turn.patch).code)
      assert.equals(0, vim.fn.filereadable(repo .. "/added.txt"))
    end)
  end)

  describe("the user's own git state", function()
    it("leaves the index untouched", function()
      write(repo .. "/staged.txt", "staged\n")
      git_ok({ "add", "staged.txt" })
      local before = git_ok({ "diff", "--cached", "--name-status" })

      run_turn(function()
        write(repo .. "/tracked.txt", "after\n")
      end)

      assert.equals(before, git_ok({ "diff", "--cached", "--name-status" }))
    end)

    it("leaves the working tree untouched", function()
      write(repo .. "/tracked.txt", "after\n")
      write(repo .. "/untracked.txt", "loose\n")

      run_turn(function()
        write(repo .. "/tracked.txt", "after again\n")
      end)

      assert.equals("after again\n", read(repo .. "/tracked.txt"))
      assert.equals("loose\n", read(repo .. "/untracked.txt"))
    end)
  end)

  describe("linked worktrees", function()
    it("does not pick up changes made in the parent worktree", function()
      local wt = repo .. "-wt"
      git_ok({ "worktree", "add", "-q", "-b", "side", wt })

      local handle = next_handle()
      GitSnapshot.ensure_baseline(handle, wt, "Bash")
      -- 親worktree側でだけ変更する。差分はリンクworktreeのスコープで取るので出てはいけない
      write(repo .. "/tracked.txt", "changed in the parent\n")
      write(wt .. "/in-worktree.txt", "mine\n")

      local files = GitSnapshot.generate(handle, nil)

      assert.same({ "in-worktree.txt" }, files)
      assert.equals(vim.fn.resolve(wt), GitSnapshot.get_root(handle))

      GitSnapshot.clear(handle)
      git_ok({ "worktree", "remove", "--force", wt })
    end)
  end)

  describe("overlapping requests in one worktree", function()
    -- ツリーは共有状態なので、2つのターンの書き込みウィンドウが重なると、どちらの差分にも
    -- 相手の変更が入る。重なりは **ベースラインを取った時点で** 記録する必要がある。差分生成時に
    -- 「今まだ動いている相手がいるか」を見るだけだと、先に終わった側しか相手を見つけられず、
    -- 相手の変更を実際に取り込んでしまう「後に終わった側」が素通りしてしまう。

    it("marks both requests when their windows overlap", function()
      local a = next_handle()
      local b = next_handle()

      GitSnapshot.ensure_baseline(a, repo, "Bash")
      GitSnapshot.ensure_baseline(b, repo, "Bash")

      assert.is_true(GitSnapshot.had_overlap(a))
      assert.is_true(GitSnapshot.had_overlap(b))
    end)

    it("still reports the overlap to the request that finishes second", function()
      -- これが一時点チェックだけでは落ちるケース。Aが先に差分を取り終えて片付いたあとでも、
      -- Bのウィンドウ（Bのベースライン〜今）にはAの変更が入っているので、Bも倒れないといけない
      local a = next_handle()
      local b = next_handle()

      GitSnapshot.ensure_baseline(a, repo, "Bash")
      GitSnapshot.ensure_baseline(b, repo, "Bash")
      GitSnapshot.clear(a)

      assert.is_true(GitSnapshot.had_overlap(b))
    end)

    it("does not mark requests that ran one after the other", function()
      local a = next_handle()
      GitSnapshot.ensure_baseline(a, repo, "Bash")
      GitSnapshot.clear(a)

      local b = next_handle()
      GitSnapshot.ensure_baseline(b, repo, "Bash")

      assert.is_false(GitSnapshot.had_overlap(b))
    end)

    it("does not mark requests running in different worktrees", function()
      local wt = repo .. "-wt"
      git_ok({ "worktree", "add", "-q", "-b", "side", wt })

      local a = next_handle()
      local b = next_handle()
      GitSnapshot.ensure_baseline(a, repo, "Bash")
      GitSnapshot.ensure_baseline(b, wt, "Bash")

      assert.is_false(GitSnapshot.had_overlap(a))
      assert.is_false(GitSnapshot.had_overlap(b))

      GitSnapshot.clear(a)
      GitSnapshot.clear(b)
      git_ok({ "worktree", "remove", "--force", wt })
    end)

    it("reports no overlap for a request that never took a baseline", function()
      assert.is_false(GitSnapshot.had_overlap(next_handle()))
      assert.is_false(GitSnapshot.had_overlap(nil))
    end)
  end)

  describe("clear and sweep", function()
    it("removes the ref it created", function()
      local handle = next_handle()
      GitSnapshot.ensure_baseline(handle, repo, "Bash")
      assert.equals(0, git({ "rev-parse", "--verify", GitSnapshot._REF_PREFIX .. handle }).code)

      GitSnapshot.clear(handle)

      assert.is_not.equals(0, git({ "rev-parse", "--verify", GitSnapshot._REF_PREFIX .. handle }).code)
      assert.is_false(GitSnapshot.has_baseline(handle))
    end)

    it("deletes every leftover ref under the namespace", function()
      GitSnapshot.ensure_baseline(next_handle(), repo, "Bash")
      GitSnapshot.ensure_baseline(next_handle(), repo, "Bash")
      -- クラッシュ相当: clear() を経ずにセッション状態だけ失う
      GitSnapshot._reset()
      assert.is_truthy(git_ok({ "for-each-ref", "--format=%(refname)", GitSnapshot._REF_PREFIX }):find("vibing"))

      GitSnapshot.sweep(repo)

      assert.equals("", git_ok({ "for-each-ref", "--format=%(refname)", GitSnapshot._REF_PREFIX }))
    end)

    it("sweeps a linked worktree that startup cleanup cannot reach", function()
      -- `refs/worktree/` はper-worktree名前空間なので、メインworktreeからの起動時sweepでは
      -- linked worktree側のrefは列挙すらされない。そこでクラッシュした分は、そのworktreeで
      -- 次にベースラインを取るときに掃除される必要がある
      local wt = repo .. "-wt"
      git_ok({ "worktree", "add", "-q", "-b", "side", wt })
      git_ok({ "update-ref", GitSnapshot._REF_PREFIX .. "crashed", "HEAD" }, wt)

      -- メインworktreeからのsweepでは届かないことをまず確認する
      GitSnapshot.sweep(repo)
      assert.equals(
        GitSnapshot._REF_PREFIX .. "crashed",
        git_ok({ "for-each-ref", "--format=%(refname)", GitSnapshot._REF_PREFIX }, wt)
      )

      local handle = next_handle()
      GitSnapshot.ensure_baseline(handle, wt, "Bash")

      local remaining = git_ok({ "for-each-ref", "--format=%(refname)", GitSnapshot._REF_PREFIX }, wt)
      assert.is_nil(remaining:find("crashed", 1, true))

      GitSnapshot.clear(handle)
      git_ok({ "worktree", "remove", "--force", wt })
    end)

    it("does not re-sweep a worktree it has already swept", function()
      -- 掃除はrootごとに1回。2つ目以降のリクエストがここを通ると、先行リクエストの生きたrefを
      -- 消してしまう（この順序が、消してよいrefの選別を不要にしている）
      local live = next_handle()
      GitSnapshot.ensure_baseline(live, repo, "Bash")

      local other = next_handle()
      GitSnapshot.ensure_baseline(other, repo, "Bash")

      assert.equals(0, git({ "rev-parse", "--verify", GitSnapshot._REF_PREFIX .. live }).code)
      assert.equals(0, git({ "rev-parse", "--verify", GitSnapshot._REF_PREFIX .. other }).code)
    end)

    it("is a no-op outside a git repository", function()
      local outside = vim.fn.tempname()
      vim.fn.mkdir(outside, "p")

      assert.has_no.errors(function()
        GitSnapshot.sweep(outside)
      end)

      vim.fn.delete(outside, "rf")
    end)
  end)
end)
