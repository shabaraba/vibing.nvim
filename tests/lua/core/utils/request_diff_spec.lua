local RequestDiff = require("vibing.core.utils.request_diff")

describe("request_diff", function()
  local tmp_dir
  local handle_id

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
    handle_id = "test-handle-" .. tostring(math.random(100000))
  end)

  after_each(function()
    RequestDiff.clear(handle_id)
    vim.fn.delete(tmp_dir, "rf")
  end)

  describe("capture", function()
    it("captures the pre-edit content of an existing file", function()
      local file = tmp_dir .. "/a.txt"
      write_file(file, "before\n")

      RequestDiff.capture(handle_id, "Edit", { file_path = file })
      assert.is_true(RequestDiff.has_capture(handle_id, file))
    end)

    it("records non-existent files so Write shows as a new file", function()
      local file = tmp_dir .. "/new.txt"
      RequestDiff.capture(handle_id, "Write", { file_path = file })
      assert.is_true(RequestDiff.has_capture(handle_id, file))
    end)

    it("ignores tools that do not modify files", function()
      RequestDiff.capture(handle_id, "Read", { file_path = tmp_dir .. "/a.txt" })
      assert.is_false(RequestDiff.has_capture(handle_id, tmp_dir .. "/a.txt"))
    end)

    it("ignores missing handle_id", function()
      local file = tmp_dir .. "/a.txt"
      write_file(file, "x\n")
      RequestDiff.capture(nil, "Edit", { file_path = file })
      -- 何も起きない（エラーにならない）ことだけ確認
    end)

    it("keeps the first backup when the same file is edited twice", function()
      local file = tmp_dir .. "/a.txt"
      write_file(file, "original\n")
      RequestDiff.capture(handle_id, "Edit", { file_path = file })

      write_file(file, "intermediate\n")
      RequestDiff.capture(handle_id, "Edit", { file_path = file })

      write_file(file, "final\n")
      local _, _, patch = RequestDiff.generate(handle_id, tmp_dir, nil)
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
      RequestDiff.capture(handle_id, "Edit", { file_path = file })
      write_file(file, "line1\nchanged\n")

      local files, abs_files, patch = RequestDiff.generate(handle_id, tmp_dir, nil)

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
      RequestDiff.capture(handle_id, "Write", { file_path = file })
      write_file(file, "hello\n")

      local files, _, patch = RequestDiff.generate(handle_id, tmp_dir, nil)

      assert.same({ "created.txt" }, files)
      assert.is_truthy(patch:find("--- /dev/null", 1, true))
      assert.is_truthy(patch:find("+++ b/created.txt", 1, true))
      assert.is_truthy(patch:find("+hello", 1, true))
    end)

    it("skips files whose content did not change", function()
      local file = tmp_dir .. "/same.txt"
      write_file(file, "unchanged\n")
      RequestDiff.capture(handle_id, "Edit", { file_path = file })

      local files, _, patch = RequestDiff.generate(handle_id, tmp_dir, nil)
      assert.same({}, files)
      assert.is_nil(patch)
    end)

    it("lists uncaptured extra paths without a diff section", function()
      local captured = tmp_dir .. "/captured.txt"
      write_file(captured, "a\n")
      RequestDiff.capture(handle_id, "Edit", { file_path = captured })
      write_file(captured, "b\n")

      local extra = tmp_dir .. "/bash-touched.txt"
      write_file(extra, "x\n")

      local files, _, patch = RequestDiff.generate(handle_id, tmp_dir, { [extra] = true })

      assert.same({ "captured.txt", "bash-touched.txt" }, files)
      assert.is_truthy(patch:find("diff --git a/captured.txt", 1, true))
      assert.is_falsy(patch:find("bash-touched.txt", 1, true))
    end)

    it("keeps requests isolated per handle_id", function()
      local other_handle = handle_id .. "-other"
      local file_a = tmp_dir .. "/a.txt"
      local file_b = tmp_dir .. "/b.txt"
      write_file(file_a, "a\n")
      write_file(file_b, "b\n")

      RequestDiff.capture(handle_id, "Edit", { file_path = file_a })
      RequestDiff.capture(other_handle, "Edit", { file_path = file_b })
      write_file(file_a, "a2\n")
      write_file(file_b, "b2\n")

      local files_a = RequestDiff.generate(handle_id, tmp_dir, nil)
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
      RequestDiff.capture(handle_id, "Edit", { file_path = outside })
      write_file(outside, "b\n")

      local files, abs_files, patch = RequestDiff.generate(handle_id, tmp_dir, nil)

      assert.same({ outside }, files)
      assert.same({ outside }, abs_files)
      assert.is_nil(patch)

      vim.fn.delete(outside_dir, "rf")
    end)

    it("lists binary files without a diff section", function()
      local file = tmp_dir .. "/bin.dat"
      write_file(file, "a\0b")
      RequestDiff.capture(handle_id, "Edit", { file_path = file })
      write_file(file, "c\0d")

      local files, _, patch = RequestDiff.generate(handle_id, tmp_dir, nil)

      assert.same({ "bin.dat" }, files)
      assert.is_nil(patch)
    end)

    it("handles files without trailing newlines so reverse-apply restores them exactly", function()
      local file = tmp_dir .. "/no-newline.txt"
      write_file(file, "one\ntwo")
      RequestDiff.capture(handle_id, "Edit", { file_path = file })
      write_file(file, "one\nTWO")

      local _, _, patch = RequestDiff.generate(handle_id, tmp_dir, nil)
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
      RequestDiff.capture(handle_id, "Edit", { file_path = file })
      write_file(file, "one\nTWO\nthree\n")

      local _, _, patch = RequestDiff.generate(handle_id, tmp_dir, nil)
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

  describe("clear", function()
    it("removes backups for the handle", function()
      local file = tmp_dir .. "/a.txt"
      write_file(file, "a\n")
      RequestDiff.capture(handle_id, "Edit", { file_path = file })
      RequestDiff.clear(handle_id)
      assert.is_false(RequestDiff.has_capture(handle_id, file))
    end)
  end)
end)
