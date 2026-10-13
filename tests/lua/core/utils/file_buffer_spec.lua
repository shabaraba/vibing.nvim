-- Neovim はバッファ名をシンボリックリンクを解いた形で持つ（macOS の `/var` は `/private/var`）。
-- 素の文字列比較で同じファイルを取り逃がすと、同名バッファを作り直して E95 で落ちる。
local FileBuffer = require("vibing.core.utils.file_buffer")

describe("file buffer", function()
  it("finds the buffer holding the file", function()
    local path = vim.fn.tempname() .. "_fb.md"
    vim.fn.writefile({ "x" }, path)
    local bufnr = vim.fn.bufadd(path)

    assert.are.equal(bufnr, FileBuffer.find(path))
  end)

  it("matches through a symlinked directory", function()
    local dir = vim.fn.tempname() .. "_fb_real"
    local link = vim.fn.tempname() .. "_fb_link"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "x" }, dir .. "/a.md")
    vim.loop.fs_symlink(dir, link)

    local bufnr = vim.fn.bufadd(dir .. "/a.md")

    assert.are.equal(bufnr, FileBuffer.find(link .. "/a.md"))
  end)

  it("answers nil for a file no buffer holds", function()
    assert.is_nil(FileBuffer.find(vim.fn.tempname() .. "_absent.md"))
  end)

  it("never matches the nameless buffers", function()
    vim.api.nvim_create_buf(false, true)

    assert.are.equal("", FileBuffer.canonical(""))
    assert.are.equal("", FileBuffer.canonical(nil))
    assert.is_nil(FileBuffer.find(""))
    assert.is_nil(FileBuffer.find(nil))
  end)

  it("keeps a path that does not exist rather than dropping it", function()
    local absent = vim.fn.tempname() .. "_absent.md"

    assert.are.equal(vim.fn.fnamemodify(absent, ":p"), FileBuffer.canonical(absent))
  end)
end)
