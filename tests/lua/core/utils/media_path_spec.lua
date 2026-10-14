-- Tests for vibing.core.utils.media_path
--
-- gx (open_url) は URL が見つからなかったとき、カーソル下のパスが画像・動画なら
-- 既定のアプリケーションへ渡す。テキストとして開くべきファイル（.lua/.md など）まで
-- 外部アプリに渡してしまわないこと、worktree 付きチャットのように Neovim の cwd と
-- チャットの working_dir が食い違う場合でも相対パスが解決できることを回帰で守る。

local MediaPath = require("vibing.core.utils.media_path")

describe("media_path.is_media", function()
  it("accepts image and video extensions", function()
    for _, path in ipairs({
      "shot.png",
      "docs/assets/demo.gif",
      "/tmp/clip.mp4",
      "a/b/c.webm",
      "diagram.svg",
    }) do
      assert.is_true(MediaPath.is_media(path))
    end
  end)

  it("ignores case", function()
    assert.is_true(MediaPath.is_media("IMG_0001.JPG"))
    assert.is_true(MediaPath.is_media("Movie.MOV"))
  end)

  it("rejects text files and paths without a media extension", function()
    for _, path in ipairs({
      "lua/vibing/config.lua",
      "README.md",
      "notes.txt",
      "Makefile",
      "archive.png.bak",
      "png",
    }) do
      assert.is_false(MediaPath.is_media(path))
    end
  end)
end)

describe("media_path.resolve", function()
  local media_file

  before_each(function()
    media_file = vim.fn.tempname() .. ".png"
    vim.fn.writefile({ "" }, media_file)
  end)

  after_each(function()
    vim.fn.delete(media_file)
  end)

  it("returns the absolute path of an existing file", function()
    assert.equals(media_file, MediaPath.resolve(media_file, nil))
  end)

  it("resolves a relative path against the given cwd", function()
    local dir = vim.fn.fnamemodify(media_file, ":h")
    local name = vim.fn.fnamemodify(media_file, ":t")
    assert.equals(media_file, MediaPath.resolve(name, dir))
  end)

  it("returns nil when the file does not exist", function()
    assert.is_nil(MediaPath.resolve(media_file .. ".missing", nil))
    assert.is_nil(MediaPath.resolve("nope.png", vim.fn.fnamemodify(media_file, ":h")))
  end)

  it("returns nil for a relative path when no cwd is given", function()
    local name = vim.fn.fnamemodify(media_file, ":t")
    assert.is_nil(MediaPath.resolve(name, nil))
  end)
end)

describe("media_path.find_under_cursor", function()
  local media_file
  local buf

  local function put_cursor_on(line, pattern)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { 1, line:find(pattern, 1, true) - 1 })
  end

  before_each(function()
    media_file = vim.fn.tempname() .. ".png"
    vim.fn.writefile({ "" }, media_file)
  end)

  after_each(function()
    vim.fn.delete(media_file)
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("finds a path wrapped in Markdown decorations", function()
    local name = vim.fn.fnamemodify(media_file, ":t")
    local dir = vim.fn.fnamemodify(media_file, ":h")

    put_cursor_on("見て: `" .. name .. "` です", name)
    assert.equals(media_file, MediaPath.find_under_cursor(dir))

    put_cursor_on("![alt](" .. name .. ")", name)
    assert.equals(media_file, MediaPath.find_under_cursor(dir))
  end)

  it("returns nil when the path under the cursor is not media", function()
    local text_file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "" }, text_file)
    put_cursor_on(text_file, text_file)
    assert.is_nil(MediaPath.find_under_cursor(nil))
    vim.fn.delete(text_file)
  end)

  it("returns nil when the media path does not exist", function()
    put_cursor_on("/no/such/place/shot.png", "shot")
    assert.is_nil(MediaPath.find_under_cursor(nil))
  end)
end)
