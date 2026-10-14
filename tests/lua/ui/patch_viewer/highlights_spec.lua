-- diffペインの配色。狙いは2つで、どちらも壊れても画面を見るまで気づけない:
--   * **前景色を置かない** こと。置いた瞬間に変更行の構文ハイライトが単色に潰れる
--   * `winhighlight` で当てること。グローバルに `DiffAdd` を上書きするとユーザーの
--     `:diffthis` まで巻き込む
local Highlights = require("vibing.ui.patch_viewer.highlights")

describe("patch_viewer.highlights", function()
  before_each(function()
    vim.api.nvim_set_hl(0, "Normal", { fg = "#CCCCCC", bg = "#1E1E1E" })
    vim.api.nvim_set_hl(0, "Added", { fg = "#00FF00" })
    vim.api.nvim_set_hl(0, "Removed", { fg = "#FF0000" })
    Highlights.define()
  end)

  it("blends towards the accent as alpha rises", function()
    assert.equals(0x000000, Highlights.blend(0xFFFFFF, 0x000000, 0))
    assert.equals(0xFFFFFF, Highlights.blend(0xFFFFFF, 0x000000, 1))
    assert.equals(0x808080, Highlights.blend(0xFFFFFF, 0x000000, 0.5))
    -- チャンネルが混ざらないこと
    assert.equals(0x804000, Highlights.blend(0xFF8000, 0x000000, 0.5))
  end)

  it("colours the background only, so syntax highlighting survives", function()
    for _, name in ipairs({
      "VibingDiffAddLine",
      "VibingDiffAddText",
      "VibingDiffDelLine",
      "VibingDiffDelText",
    }) do
      local hl = vim.api.nvim_get_hl(0, { name = name })
      assert.is_truthy(hl.bg)
      assert.is_nil(hl.fg)
    end
  end)

  it("makes the changed characters stronger than the line they sit on", function()
    local base = vim.api.nvim_get_hl(0, { name = "Normal" }).bg
    local line = vim.api.nvim_get_hl(0, { name = "VibingDiffAddLine" }).bg
    local text = vim.api.nvim_get_hl(0, { name = "VibingDiffAddText" }).bg

    -- アクセントは純緑なので、濃くなるほど緑成分が増える
    local function green(color)
      return math.floor(color / 256) % 256
    end
    assert.is_true(green(line) > green(base))
    assert.is_true(green(text) > green(line))
  end)

  it("points the same diff group at opposite colours on each side", function()
    local before = Highlights.win_highlight("before")
    local after = Highlights.win_highlight("after")

    -- 片側にしかない行はどちらの窓でも `DiffAdd` になる。だから窓ごとに向き先を変える
    assert.is_truthy(before:find("DiffAdd:VibingDiffDelLine", 1, true))
    assert.is_truthy(after:find("DiffAdd:VibingDiffAddLine", 1, true))
    -- 0.11 で足された `DiffTextAdd` を落とすと、そこだけカラースキームの色が出る
    assert.is_truthy(before:find("DiffTextAdd:VibingDiffDelText", 1, true))
    assert.is_truthy(after:find("DiffTextAdd:VibingDiffAddText", 1, true))
  end)

  it("keeps unrelated winhighlight entries and leaves the global groups alone", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = 10,
      height = 5,
      row = 1,
      col = 1,
    })
    vim.wo[win].winhighlight = "Normal:NormalFloat,DiffAdd:SomethingStale"

    Highlights.apply(win, "after")

    local value = vim.wo[win].winhighlight
    assert.is_truthy(value:find("Normal:NormalFloat", 1, true))
    assert.is_falsy(value:find("SomethingStale", 1, true))
    assert.is_truthy(value:find("DiffAdd:VibingDiffAddLine", 1, true))
    -- グローバルの `DiffAdd` は触らない
    assert.same({ fg = 16711680 }, vim.api.nvim_get_hl(0, { name = "Removed" }))

    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
