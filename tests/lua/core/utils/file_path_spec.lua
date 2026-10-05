-- `### Modified Files` はファイルを1行ずつ並べるのをやめ、1行サマリになった。その行は
-- パスではないので、ここで弾かないと `gf` が `<cwd>/3 files changed: ...` を開こうとする。
local FilePath = require("vibing.core.utils.file_path")

describe("file_path.is_cursor_on_file_path", function()
  local buf

  local function open(lines, row)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    return buf
  end

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("declines the one-line summary", function()
    open({ "### Modified Files", "", "3 files changed: a.lua, b.lua, c.lua" }, 3)
    assert.is_nil(FilePath.is_cursor_on_file_path(buf))
  end)

  it("declines the singular form too", function()
    open({ "### Modified Files", "", "1 file changed: a.lua" }, 3)
    assert.is_nil(FilePath.is_cursor_on_file_path(buf))
  end)

  it("still accepts a path listed on its own line", function()
    -- 1行ずつ並べていた頃のチャットは今も開かれる
    open({ "### Modified Files", "", "lua/vibing/init.lua" }, 3)
    assert.is_truthy(FilePath.is_cursor_on_file_path(buf))
  end)

  it("still accepts a path that happens to start with digits", function()
    open({ "### Modified Files", "", "2024_notes.md" }, 3)
    assert.is_truthy(FilePath.is_cursor_on_file_path(buf))
  end)

  it("declines a line outside the section", function()
    open({ "## Assistant", "", "lua/vibing/init.lua" }, 3)
    assert.is_nil(FilePath.is_cursor_on_file_path(buf))
  end)
end)

-- plenary は spec ファイルごとに子 Neovim を立てるので、固定パスは共有されてしまう
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local target = dir .. "/target.lua"
vim.fn.writefile({ "one", "two", "three" }, target)

-- リンク先は、行指定付きなのか `:` を名前に含むファイルなのか、ファイルシステムに
-- 聞くまで区別がつかない。候補を順に試して最初に実在したものを採る。
describe("file_path.resolve_link_dest", function()
  it("resolves an absolute destination", function()
    assert.equals(target, FilePath.resolve_link_dest(target, nil))
  end)

  it("resolves a relative destination against the given cwd", function()
    assert.equals(target, FilePath.resolve_link_dest("target.lua", dir))
  end)

  it("carries the line number of a :42 suffix", function()
    local path, lnum = FilePath.resolve_link_dest(target .. ":2", nil)
    assert.equals(target, path)
    assert.equals(2, lnum)
  end)

  it("carries the line number of a #L42 suffix", function()
    local path, lnum = FilePath.resolve_link_dest(target .. "#L3", nil)
    assert.equals(target, path)
    assert.equals(3, lnum)
  end)

  it("drops a section anchor that is not a line number", function()
    local path, lnum = FilePath.resolve_link_dest(target .. "#some-section", nil)
    assert.equals(target, path)
    assert.is_nil(lnum)
  end)

  it("prefers a file whose name really contains the suffix", function()
    local odd = dir .. "/odd.lua:2"
    vim.fn.writefile({ "" }, odd)
    local path, lnum = FilePath.resolve_link_dest(odd, nil)
    assert.equals(odd, path)
    assert.is_nil(lnum)
    vim.fn.delete(odd)
  end)

  it("declines a destination that does not exist", function()
    -- 実在しないパスを返すと `gf` の `<cfile>` 経路に回らなくなる
    assert.is_nil(FilePath.resolve_link_dest(dir .. "/missing.lua", nil))
  end)
end)

-- `gf` / `gd` を `gx` と揃える。ラベルの上では `<cfile>` がラベルの文字列を拾うので、
-- リンク記法そのものを読まないと飛べない。
describe("file_path.find_link_target_under_cursor", function()
  local buf

  local function open(line, col)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { 1, col - 1 })
    return buf
  end

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("resolves the destination from the label", function()
    local line = "see [the target module](" .. target .. ") here"
    open(line, line:find("target module"))
    assert.equals(target, FilePath.find_link_target_under_cursor(buf))
  end)

  it("leaves a URL to gx", function()
    local line = "[docs](https://example.com/a.lua)"
    open(line, line:find("docs"))
    assert.is_nil(FilePath.find_link_target_under_cursor(buf))
  end)

  it("declines a same-document anchor", function()
    local line = "[section](#invariants)"
    open(line, 2)
    assert.is_nil(FilePath.find_link_target_under_cursor(buf))
  end)

  it("declines when the cursor is outside the notation", function()
    local line = "see [the target](" .. target .. ") here"
    open(line, 1)
    assert.is_nil(FilePath.find_link_target_under_cursor(buf))
  end)
end)
