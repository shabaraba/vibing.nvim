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
