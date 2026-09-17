local RequestDiff = require("vibing.core.utils.request_diff")

describe("request_diff", function()
  local tmp_dir
  local turn_id

  local function write_file(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
  end

  local function read_file(path)
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    local content = f:read("*a")
    f:close()
    return content
  end

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    tmp_dir = vim.fn.fnamemodify(tmp_dir, ":p"):gsub("/$", "")
    turn_id = "test-handle-" .. tostring(math.random(100000))
  end)

  after_each(function()
    RequestDiff.clear(turn_id)
    vim.fn.delete(tmp_dir, "rf")
  end)

  describe("capture", function()
    it("captures the pre-edit content of an existing file", function()
      local file = tmp_dir .. "/a.txt"
      write_file(file, "before\n")

      RequestDiff.capture(turn_id, "Edit", { file_path = file })
      assert.is_true(RequestDiff.has_capture(turn_id, file))
    end)

    it("records non-existent files so Write shows as a new file", function()
      local file = tmp_dir .. "/new.txt"
      RequestDiff.capture(turn_id, "Write", { file_path = file })
      assert.is_true(RequestDiff.has_capture(turn_id, file))
    end)

    it("ignores tools that do not modify files", function()
      RequestDiff.capture(turn_id, "Read", { file_path = tmp_dir .. "/a.txt" })
      assert.is_false(RequestDiff.has_capture(turn_id, tmp_dir .. "/a.txt"))
    end)

    it("ignores missing turn_id", function()
      local file = tmp_dir .. "/a.txt"
      write_file(file, "x\n")
      RequestDiff.capture(nil, "Edit", { file_path = file })
      -- 何も起きない（エラーにならない）ことだけ確認
    end)

    it("keeps the first backup when the same file is edited twice", function()
      local file = tmp_dir .. "/a.txt"
      write_file(file, "original\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })

      write_file(file, "intermediate\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })

      write_file(file, "final\n")
      local _, _, patch = RequestDiff.generate(turn_id, tmp_dir, nil)
      assert.is_truthy(patch)
      assert.is_truthy(patch:find("-original", 1, true))
      assert.is_truthy(patch:find("+final", 1, true))
      assert.is_falsy(patch:find("intermediate", 1, true))
    end)
  end)

  describe("generate", function()
    it("produces a git-style patch for a modified file", function()
      local file = tmp_dir .. "/mod.txt"
      write_file(file, "line1\nline2\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })
      write_file(file, "line1\nchanged\n")

      local files, abs_files, patch = RequestDiff.generate(turn_id, tmp_dir, nil)

      assert.same({ "mod.txt" }, files)
      assert.same({ file }, abs_files)
      assert.is_truthy(patch:find("# vibing-request-diff base: " .. tmp_dir, 1, true))
      assert.is_truthy(patch:find("diff --git a/mod.txt b/mod.txt", 1, true))
      assert.is_truthy(patch:find("--- a/mod.txt", 1, true))
      assert.is_truthy(patch:find("+++ b/mod.txt", 1, true))
      assert.is_truthy(patch:find("-line2", 1, true))
      assert.is_truthy(patch:find("+changed", 1, true))
    end)

    it("produces a /dev/null header for newly created files", function()
      local file = tmp_dir .. "/created.txt"
      RequestDiff.capture(turn_id, "Write", { file_path = file })
      write_file(file, "hello\n")

      local files, _, patch = RequestDiff.generate(turn_id, tmp_dir, nil)

      assert.same({ "created.txt" }, files)
      assert.is_truthy(patch:find("--- /dev/null", 1, true))
      assert.is_truthy(patch:find("+++ b/created.txt", 1, true))
      assert.is_truthy(patch:find("+hello", 1, true))
    end)

    it("skips files whose content did not change", function()
      local file = tmp_dir .. "/same.txt"
      write_file(file, "unchanged\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })

      local files, _, patch = RequestDiff.generate(turn_id, tmp_dir, nil)
      assert.same({}, files)
      assert.is_nil(patch)
    end)

    it("lists uncaptured extra paths without a diff section", function()
      local captured = tmp_dir .. "/captured.txt"
      write_file(captured, "a\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = captured })
      write_file(captured, "b\n")

      local extra = tmp_dir .. "/bash-touched.txt"
      write_file(extra, "x\n")

      local files, _, patch = RequestDiff.generate(turn_id, tmp_dir, { [extra] = true })

      assert.same({ "captured.txt", "bash-touched.txt" }, files)
      assert.is_truthy(patch:find("diff --git a/captured.txt", 1, true))
      assert.is_falsy(patch:find("bash-touched.txt", 1, true))
    end)

    it("excludes .vibing paths from both captures and event fallback", function()
      local internal = tmp_dir .. "/.vibing/worktrees/other/lua/plugin.lua"
      vim.fn.mkdir(vim.fn.fnamemodify(internal, ":h"), "p")
      write_file(internal, "before\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = internal })
      write_file(internal, "after\n")

      local files, abs_files, patch = RequestDiff.generate(
        turn_id,
        tmp_dir,
        { [internal] = true }
      )

      assert.same({}, files)
      assert.same({}, abs_files)
      assert.is_nil(patch)
    end)

    it("keeps normal files when the base directory itself is inside .vibing", function()
      local worktree = tmp_dir .. "/.vibing/worktrees/feature"
      vim.fn.mkdir(worktree, "p")
      local file = worktree .. "/lua/plugin.lua"
      vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
      write_file(file, "before\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })
      write_file(file, "after\n")

      local files, abs_files, patch = RequestDiff.generate(turn_id, worktree, nil)

      assert.same({ "lua/plugin.lua" }, files)
      assert.same({ file }, abs_files)
      assert.is_truthy(patch:find("diff --git a/lua/plugin.lua", 1, true))
    end)

    it("keeps requests isolated per turn_id", function()
      local other_handle = turn_id .. "-other"
      local file_a = tmp_dir .. "/a.txt"
      local file_b = tmp_dir .. "/b.txt"
      write_file(file_a, "a\n")
      write_file(file_b, "b\n")

      RequestDiff.capture(turn_id, "Edit", { file_path = file_a })
      RequestDiff.capture(other_handle, "Edit", { file_path = file_b })
      write_file(file_a, "a2\n")
      write_file(file_b, "b2\n")

      local files_a = RequestDiff.generate(turn_id, tmp_dir, nil)
      local files_b = RequestDiff.generate(other_handle, tmp_dir, nil)

      assert.same({ "a.txt" }, files_a)
      assert.same({ "b.txt" }, files_b)

      RequestDiff.clear(other_handle)
    end)

    it("lists files outside base_dir without a diff section", function()
      local outside_dir = vim.fn.tempname()
      vim.fn.mkdir(outside_dir, "p")
      outside_dir = vim.fn.fnamemodify(outside_dir, ":p"):gsub("/$", "")
      local outside = outside_dir .. "/outside.txt"
      write_file(outside, "a\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = outside })
      write_file(outside, "b\n")

      local files, abs_files, patch = RequestDiff.generate(turn_id, tmp_dir, nil)

      assert.same({ outside }, files)
      assert.same({ outside }, abs_files)
      assert.is_nil(patch)

      vim.fn.delete(outside_dir, "rf")
    end)

    it("lists binary files without a diff section", function()
      local file = tmp_dir .. "/bin.dat"
      write_file(file, "a\0b")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })
      write_file(file, "c\0d")

      local files, _, patch = RequestDiff.generate(turn_id, tmp_dir, nil)

      assert.same({ "bin.dat" }, files)
      assert.is_nil(patch)
    end)

    it("handles files without trailing newlines so reverse-apply restores them exactly", function()
      local file = tmp_dir .. "/no-newline.txt"
      write_file(file, "one\ntwo")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })
      write_file(file, "one\nTWO")

      local _, _, patch = RequestDiff.generate(turn_id, tmp_dir, nil)
      assert.is_truthy(patch)
      assert.is_truthy(patch:find("No newline at end of file", 1, true))

      local patch_file = tmp_dir .. "/nn.patch"
      local parser = require("vibing.ui.patch_viewer.parser")
      write_file(patch_file, parser.extract_file_diff(patch, "no-newline.txt") .. "\n")
      local result = vim
        .system({ "git", "apply", "--reverse", "--whitespace=nowarn", patch_file }, { cwd = tmp_dir, text = true })
        :wait()
      assert.equals(0, result.code, result.stderr)
      assert.equals("one\ntwo", read_file(file))
    end)

    it("is compatible with the patch viewer parser and git apply --reverse", function()
      local file = tmp_dir .. "/roundtrip.txt"
      write_file(file, "one\ntwo\nthree\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })
      write_file(file, "one\nTWO\nthree\n")

      local _, _, patch = RequestDiff.generate(turn_id, tmp_dir, nil)
      local parser = require("vibing.ui.patch_viewer.parser")

      assert.equals(tmp_dir, parser.extract_base_dir(patch))
      local listed = parser.extract_files(patch)
      assert.same({ "roundtrip.txt" }, listed)

      local file_diff = parser.extract_file_diff(patch, "roundtrip.txt")
      assert.is_truthy(file_diff)

      -- リバース適用で変更前の内容に戻ること
      local patch_file = tmp_dir .. "/x.patch"
      write_file(patch_file, file_diff .. "\n")
      local result = vim
        .system({ "git", "apply", "--reverse", "--whitespace=nowarn", patch_file }, { cwd = tmp_dir, text = true })
        :wait()
      assert.equals(0, result.code, result.stderr)
      assert.equals("one\ntwo\nthree\n", read_file(file))
    end)
  end)

  describe("sections_for", function()
    -- スナップショット経路（git_snapshot）はgitignore対象の変更をツリー差分に出せない（#735）。
    -- 退避があるファイルだけ、patchに継ぎ足すセクションを合成する

    it("synthesizes a section from the backup for a captured file", function()
      local file = tmp_dir .. "/ignored.txt"
      write_file(file, "before\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })
      write_file(file, "after\n")

      local sections, resolved = RequestDiff.sections_for(turn_id, tmp_dir, { file })

      assert.equals(1, #sections)
      assert.is_truthy(sections[1]:find("diff --git a/ignored.txt b/ignored.txt", 1, true))
      assert.is_truthy(sections[1]:find("-before", 1, true))
      assert.is_truthy(sections[1]:find("+after", 1, true))
      assert.is_true(resolved[file])
    end)

    it("synthesizes a new-file section for a Write that created the file", function()
      local file = tmp_dir .. "/created.txt"
      RequestDiff.capture(turn_id, "Write", { file_path = file })
      write_file(file, "hello\n")

      local sections, resolved = RequestDiff.sections_for(turn_id, tmp_dir, { file })

      assert.equals(1, #sections)
      assert.is_truthy(sections[1]:find("--- /dev/null", 1, true))
      assert.is_true(resolved[file])
    end)

    it("leaves a path with no backup unresolved so the caller can warn", function()
      -- Bash由来・codexのapply_patch由来の変更はツールイベントに名前が出ても退避が無い。
      -- 合成できないことを黙って流すと「一覧に載るのにpatchが無い」が再発する
      local file = tmp_dir .. "/bash-touched.txt"
      write_file(file, "x\n")

      local sections, resolved = RequestDiff.sections_for(turn_id, tmp_dir, { file })

      assert.same({}, sections)
      assert.is_nil(resolved[file])
    end)

    it("resolves an unchanged captured file without a section", function()
      -- 変更が無かったことは退避から判断できている。警告対象にしてはいけない
      local file = tmp_dir .. "/same.txt"
      write_file(file, "unchanged\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })

      local sections, resolved = RequestDiff.sections_for(turn_id, tmp_dir, { file })

      assert.same({}, sections)
      assert.is_true(resolved[file])
    end)

    it("does not consume the backups (clear still owns their lifetime)", function()
      local file = tmp_dir .. "/keep.txt"
      write_file(file, "a\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })
      write_file(file, "b\n")

      RequestDiff.sections_for(turn_id, tmp_dir, { file })

      assert.is_true(RequestDiff.has_capture(turn_id, file))
    end)
  end)

  describe("clear", function()
    it("removes backups for the handle", function()
      local file = tmp_dir .. "/a.txt"
      write_file(file, "a\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })
      RequestDiff.clear(turn_id)
      assert.is_false(RequestDiff.has_capture(turn_id, file))
    end)
  end)

  describe("the TTL sweep of abandoned sessions", function()
    -- スイープは `capture()` のたびに走る＝同じNeovim内の別チャットがツールを呼ぶたびに走る。
    -- 年齢だけで刈ると、1時間を超えて開いているターン（承認待ちで人間を待っている間がまさに
    -- それ）の退避が実行中のまま消え、そのターンの差分が警告もなく空になる。
    -- `git_snapshot` の同名 describe と対になっている。
    local registry = require("vibing.infrastructure.adapter.modules.turn_registry")
    local extra_turns

    ---@param turn string
    local function age(turn)
      local session = RequestDiff._session(turn)
      assert.is_not_nil(session)
      session.created = os.time() - 7 * 24 * 3600
    end

    ---スイープを起こす側のターン。後片付けのために覚えておく
    ---@return string
    local function sweeping_capture()
      local other = "sweeper-" .. tostring(math.random(100000))
      table.insert(extra_turns, other)
      local file = tmp_dir .. "/sweeper.txt"
      write_file(file, "x\n")
      RequestDiff.capture(other, "Edit", { file_path = file })
      return other
    end

    before_each(function()
      extra_turns = {}
    end)

    after_each(function()
      for _, turn in ipairs(extra_turns) do
        RequestDiff.clear(turn)
        pcall(registry.close, turn)
      end
    end)

    it("keeps an old session whose turn is still open", function()
      local file = tmp_dir .. "/long.txt"
      write_file(file, "a\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })
      registry.open({ turn_id = turn_id })
      table.insert(extra_turns, turn_id)
      age(turn_id)

      sweeping_capture()

      assert.is_true(RequestDiff.has_capture(turn_id, file))
    end)

    it("reaps an old session whose turn is over", function()
      -- TTL はテーブルが際限なく育たないための外枠として残っている。レジストリに居ない
      -- ＝そのストリームは終わっている（clear されなかった残骸）
      local abandoned = "abandoned-" .. tostring(math.random(100000))
      local file = tmp_dir .. "/abandoned.txt"
      write_file(file, "a\n")
      RequestDiff.capture(abandoned, "Edit", { file_path = file })
      age(abandoned)

      sweeping_capture()

      assert.is_false(RequestDiff.has_capture(abandoned, file))
    end)

    it("reaps an old session even while some other turn is open", function()
      -- `turn_still_open` は **そのターン** について訊き、フォールバックを取ってはいけない。
      -- sole-open の推測を継いでいると、どこかで1つ動いているだけで全残骸が「実行中」になり、
      -- スイープが止まって tmp が際限なく育つ
      local abandoned = "abandoned-" .. tostring(math.random(100000))
      local file = tmp_dir .. "/abandoned.txt"
      write_file(file, "a\n")
      RequestDiff.capture(abandoned, "Edit", { file_path = file })
      age(abandoned)

      local elsewhere = "elsewhere-" .. tostring(math.random(100000))
      registry.open({ turn_id = elsewhere })
      table.insert(extra_turns, elsewhere)

      sweeping_capture()

      assert.is_false(RequestDiff.has_capture(abandoned, file))
    end)

    it("does not touch a session that is merely recent", function()
      local file = tmp_dir .. "/recent.txt"
      write_file(file, "a\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })

      sweeping_capture()

      assert.is_true(RequestDiff.has_capture(turn_id, file))
    end)

    it("keeps the pre-edit content of a long turn readable after another turn sweeps", function()
      -- 消えると `generate` は退避を見つけられず、そのターンの差分が空になる。「バックアップが
      -- 生きている」だけでなく「中身が退避時点のまま読める」ことまで見る
      local file = tmp_dir .. "/long.txt"
      write_file(file, "before the long wait\n")
      RequestDiff.capture(turn_id, "Edit", { file_path = file })
      registry.open({ turn_id = turn_id })
      table.insert(extra_turns, turn_id)
      age(turn_id)

      sweeping_capture()
      write_file(file, "after the long wait\n")

      local files, _, patch = RequestDiff.generate(turn_id, tmp_dir)
      assert.same({ "long.txt" }, files)
      assert.is_truthy(patch, "the long turn must still produce a patch")
      assert.is_truthy(patch:match("before the long wait"), patch)
      assert.is_truthy(patch:match("after the long wait"), patch)
    end)
  end)
end)
