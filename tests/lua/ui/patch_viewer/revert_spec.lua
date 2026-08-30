-- patch_viewer の revert は、patch本文の先頭にある `# vibing-request-diff base: <dir>` を
-- 見て2つに分岐する。ヘッダがあれば `git apply --reverse` を base_dir で回し、無ければ
-- 「削除されたmote統合が書いた古いpatch」として明示的に断る。
--
-- 後者は表示だけできて逆適用はできない、という中途半端な状態を意図的に選んだ分岐なので、
-- 断り方が黙って通る側に倒れないことを固定しておく。
local Revert = require("vibing.ui.patch_viewer.revert")

describe("patch_viewer.revert", function()
  local repo
  local notifications

  local function git_ok(args)
    local cmd = { "git" }
    vim.list_extend(cmd, args)
    local result = vim.system(cmd, { cwd = repo, text = true }):wait()
    assert.equals(0, result.code, table.concat(args, " ") .. ": " .. tostring(result.stderr))
    return vim.trim(result.stdout or "")
  end

  local function write(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
  end

  local function read(path)
    local f = assert(io.open(path, "rb"))
    local content = f:read("*a")
    f:close()
    return content
  end

  ---patchファイルを書き出してそのパスを返す
  local function patch_file(content)
    local path = vim.fn.tempname() .. ".patch"
    write(path, content)
    return path
  end

  ---最後に出た通知のメッセージ
  local function last_message()
    return notifications[#notifications] and notifications[#notifications].msg or nil
  end

  local original_notify

  before_each(function()
    notifications = {}
    original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    repo = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(repo, "p")
    git_ok({ "init", "-q" })
    git_ok({ "config", "user.email", "test@example.com" })
    git_ok({ "config", "user.name", "test" })
    write(repo .. "/tracked.txt", "before\n")
    git_ok({ "add", "." })
    git_ok({ "commit", "-q", "-m", "init" })
  end)

  after_each(function()
    vim.notify = original_notify
    if repo then
      vim.fn.delete(repo, "rf")
    end
  end)

  describe("a patch written by the removed mote integration", function()
    -- baseヘッダが無く、`diff --mote` ヘッダで始まる。parser側は今も読めるので
    -- 一覧表示はできるが、逆適用はできない
    local mote_patch = table.concat({
      "diff --mote a/tracked.txt b/tracked.txt",
      "--- a/tracked.txt",
      "+++ b/tracked.txt",
      "@@ -1 +1 @@",
      "-before",
      "+after",
      "",
    }, "\n")

    it("refuses a single-file revert and says why", function()
      local ok = Revert.revert_single_file(nil, patch_file(mote_patch), "tracked.txt")

      assert.is_false(ok)
      assert.is_truthy(last_message():find("mote", 1, true))
      assert.is_truthy(last_message():find("can no longer be reverted", 1, true))
    end)

    it("refuses a revert-all and says why", function()
      local ok = Revert.revert_all_files(nil, patch_file(mote_patch))

      assert.is_false(ok)
      assert.is_truthy(last_message():find("mote", 1, true))
    end)

    it("leaves the file on disk untouched", function()
      Revert.revert_single_file(nil, patch_file(mote_patch), "tracked.txt")

      assert.equals("before\n", read(repo .. "/tracked.txt"))
    end)
  end)

  describe("a patch written by the git tree snapshot", function()
    ---いま git_snapshot.generate が書くのと同じ形（baseヘッダ + git形式diff）
    local function snapshot_patch()
      return table.concat({
        "# vibing-request-diff base: " .. repo,
        "diff --git a/tracked.txt b/tracked.txt",
        "index 0000000..1111111 100644",
        "--- a/tracked.txt",
        "+++ b/tracked.txt",
        "@@ -1 +1 @@",
        "-before",
        "+after",
        "",
      }, "\n")
    end

    it("reverse-applies it against the base dir in the header", function()
      -- ターンが書いた後の状態にしておいて、patchを逆適用して戻す
      write(repo .. "/tracked.txt", "after\n")

      local ok = Revert.revert_single_file(nil, patch_file(snapshot_patch()), "tracked.txt")

      assert.is_true(ok)
      assert.equals("before\n", read(repo .. "/tracked.txt"))
    end)

    it("resolves the reload path against the base dir, not Neovim's cwd", function()
      -- patch内のパスはbase_dir相対。Neovimのcwdがrepoの外にあっても、リロード対象は
      -- repo側の実ファイルでなければならない
      assert.is_not.equals(repo, vim.fn.getcwd())
      write(repo .. "/tracked.txt", "after\n")

      assert.is_true(Revert.revert_single_file(nil, patch_file(snapshot_patch()), "tracked.txt"))

      local bufnr = vim.fn.bufnr(repo .. "/tracked.txt")
      if bufnr ~= -1 then
        assert.equals("before", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
      end
    end)
  end)
end)
