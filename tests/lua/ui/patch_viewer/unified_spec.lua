-- unifiedの描画。`unified_lines` が正しく分解できていても、extmarkを置き忘れれば画面は
-- 素のコードが並ぶだけになり、どこが変わったのか分からなくなる
local Unified = require("vibing.ui.patch_viewer.unified")
local Highlights = require("vibing.ui.patch_viewer.highlights")

local NS = vim.api.nvim_get_namespaces()["vibing_patch_viewer_unified"]

describe("patch_viewer.unified", function()
  local PATCH = table.concat({
    "diff --git a/a.lua b/a.lua",
    "--- a/a.lua",
    "+++ b/a.lua",
    "@@ -10,3 +10,3 @@",
    "   local x = 1",
    "-  return x",
    "+  return x + 1",
    " end",
  }, "\n")

  local win, buf

  before_each(function()
    vim.api.nvim_set_hl(0, "Normal", { fg = "#CCCCCC", bg = "#1E1E1E" })
    local scratch = vim.api.nvim_create_buf(false, true)
    win = vim.api.nvim_open_win(scratch, false, {
      relative = "editor",
      width = 40,
      height = 10,
      row = 1,
      col = 1,
    })
    buf = Unified.render(win, "a.lua", PATCH, "a.lua")
  end)

  after_each(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end)

  ---@return table<number, vim.api.keyset.get_extmark_item[]>
  local function marks_by_row()
    local out = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })) do
      out[mark[2]] = out[mark[2]] or {}
      table.insert(out[mark[2]], mark)
    end
    return out
  end

  it("gives the file's own filetype to the buffer, so syntax highlighting runs", function()
    assert.equals("lua", vim.bo[buf].filetype)
    assert.is_false(vim.bo[buf].modifiable)
  end)

  it("tints the whole added and removed lines, past the end of the text", function()
    local marks = marks_by_row()

    -- `line_hl_group` は行末より先まで塗る。`hl_group` だと短い行で帯が途切れる
    assert.equals("VibingDiffDelLine", marks[2][1][4].line_hl_group)
    assert.equals("VibingDiffAddLine", marks[3][1][4].line_hl_group)
    assert.is_nil(marks[1])
  end)

  it("marks the changed characters inside the added line", function()
    local added = marks_by_row()[3]
    local text_mark

    for _, mark in ipairs(added) do
      if mark[4].hl_group == "VibingDiffAddText" then
        text_mark = mark
      end
    end

    assert.is_truthy(text_mark)
    assert.equals(10, text_mark[3])
    assert.equals(14, text_mark[4].end_col)
  end)

  it("overrides the foreground on the hunk header, which is not code", function()
    local hunk = marks_by_row()[0][1]

    assert.equals("VibingDiffHunk", hunk[4].hl_group)
    assert.equals("VibingDiffHunk", hunk[4].line_hl_group)
    Highlights.define()
    assert.is_truthy(vim.api.nvim_get_hl(0, { name = "VibingDiffHunk" }).fg)
  end)

  it("puts the file's line numbers and the +/- into the gutter", function()
    local function gutter(lnum)
      return vim.api.nvim_eval_statusline(vim.wo[win].statuscolumn, {
        winid = win,
        use_statuscol_lnum = lnum,
      }).str
    end

    assert.equals("      ", gutter(1)) -- `@@` の行はどのファイルの行でもない
    assert.equals(" 10   ", gutter(2))
    assert.equals(" 11 - ", gutter(3)) -- 削除は変更前の行番号
    assert.equals(" 11 + ", gutter(4)) -- 追加は変更後の行番号
    assert.equals(" 12   ", gutter(5))
  end)

  it("hands the window back the way it found it", function()
    local scratch = vim.api.nvim_create_buf(false, true)
    local other = vim.api.nvim_open_win(scratch, false, {
      relative = "editor",
      width = 40,
      height = 10,
      row = 1,
      col = 1,
    })
    vim.wo[other].number = true
    vim.wo[other].foldcolumn = "2"

    Unified.render(other, "a.lua", PATCH, "a.lua")
    assert.is_false(vim.wo[other].number)

    Unified.reset_window(other)
    assert.equals("", vim.wo[other].statuscolumn)
    assert.is_true(vim.wo[other].number)
    assert.equals("2", vim.wo[other].foldcolumn)

    vim.api.nvim_win_close(other, true)
  end)
end)
