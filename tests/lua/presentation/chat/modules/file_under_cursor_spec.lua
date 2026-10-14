-- `gf` が「どのファイルのことか」を決める順序。順序が入れ替わると、リンク記法の中で
-- `<cfile>` がラベルの文字列を拾う（記法の中なのに別物を開くか、何も開かない）。
local FileUnderCursor = require("vibing.presentation.chat.modules.file_under_cursor")

describe("file_under_cursor.resolve", function()
  local buf

  -- plenary は spec ファイルごとに子 Neovim を立てるので、固定パスは共有されてしまう
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local target = dir .. "/target.lua"
  vim.fn.writefile({ "one", "two", "three" }, target)

  local function open(lines, row, col)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { row, col - 1 })
    return buf
  end

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  for _, format in ipairs({
    { label = "Diff: ", path = ".vibing/diffs/x.diff" },
    { label = "Patch: ", path = ".vibing/patches/x.patch" },
  }) do
    it("reads the full " .. format.label .. "path containing spaces for gf", function()
      local path = dir .. "/My Project/" .. format.path
      vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
      vim.fn.writefile({ "diff --git a/x b/x" }, path)
      local line = format.label .. path
      open({ "### Modified Files", "", line }, 3, line:find("My Project"))
      assert.equals(path, FileUnderCursor.resolve(buf))
    end)

    it("does not open a truncated " .. format.label .. "path when the full path is missing", function()
      local line = format.label .. target .. " /missing." .. format.path:match("%.(%a+)$")
      open({ "### Modified Files", "", line }, 3, #format.label + 1)
      assert.is_nil(FileUnderCursor.resolve(buf))
    end)
  end

  it("takes a path line in the Modified Files section first", function()
    open({ "### Modified Files", "", target }, 3, 1)
    assert.equals(target, FileUnderCursor.resolve(buf))
  end)

  it("takes a Markdown link from its label, where <cfile> would read the label", function()
    local line = "see [the target module](" .. target .. ") here"
    open({ "## Assistant", "", line }, 3, line:find("target module"))
    local path, lnum = FileUnderCursor.resolve(buf)
    assert.equals(target, path)
    assert.is_nil(lnum)
  end)

  it("carries the line number a link asked for", function()
    local line = "[go](" .. target .. ":2)"
    open({ "## Assistant", "", line }, 3, 2)
    local path, lnum = FileUnderCursor.resolve(buf)
    assert.equals(target, path)
    assert.equals(2, lnum)
  end)

  it("falls back to <cfile> outside a link", function()
    open({ "## Assistant", "", "the file " .. target .. " changed" }, 3, 10)
    assert.equals(target, FileUnderCursor.resolve(buf))
  end)

  it("resolves nothing when <cfile> names no readable file", function()
    open({ "## Assistant", "", "just some prose here" }, 3, 6)
    assert.is_nil(FileUnderCursor.resolve(buf))
  end)

  it("resolves nothing on an empty line", function()
    open({ "## Assistant", "", "" }, 3, 1)
    assert.is_nil(FileUnderCursor.resolve(buf))
  end)
end)
