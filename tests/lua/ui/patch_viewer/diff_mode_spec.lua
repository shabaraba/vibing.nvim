-- `diffopt` はグローバルオプション。フロートのために書き換える以上、**必ず元に戻る** ことと
-- **ユーザーの設定を捨てない** ことがこのモジュールの存在理由。
local DiffMode = require("vibing.ui.patch_viewer.diff_mode")

describe("patch_viewer.diff_mode", function()
  local saved_diffopt
  local saved_fillchars

  before_each(function()
    saved_diffopt = vim.o.diffopt
    saved_fillchars = vim.o.fillchars
  end)

  after_each(function()
    vim.o.diffopt = saved_diffopt
    vim.o.fillchars = saved_fillchars
  end)

  it("keeps the user's own diffopt keys", function()
    local kept = DiffMode.keep("iwhite,internal,closeoff,algorithm:myers,linematch:40")

    assert.is_truthy(vim.tbl_contains(kept, "iwhite"))
    assert.is_truthy(vim.tbl_contains(kept, "closeoff"))
    -- こちらが差し替えるキーは残さない。残すと同じキーが2つ並ぶ
    assert.is_falsy(vim.tbl_contains(kept, "algorithm:myers"))
    assert.is_falsy(vim.tbl_contains(kept, "linematch:40"))
  end)

  it("applies its own keys and restores the original", function()
    vim.o.diffopt = "internal,filler,closeoff,algorithm:myers"

    local saved = DiffMode.apply()
    assert.equals("internal,filler,closeoff,algorithm:myers", saved)
    assert.is_truthy(vim.o.diffopt:find("algorithm:histogram", 1, true))
    assert.is_falsy(vim.o.diffopt:find("algorithm:myers", 1, true))
    -- ユーザー由来のキーは持ち越す
    assert.is_truthy(vim.o.diffopt:find("closeoff", 1, true))

    DiffMode.restore(saved)
    assert.equals("internal,filler,closeoff,algorithm:myers", vim.o.diffopt)
  end)

  it("sets the diff fillchar on one window without clobbering the others", function()
    vim.o.fillchars = "eob: ,vert:│"
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = 10,
      height = 5,
      row = 1,
      col = 1,
    })

    DiffMode.set_fill_char(win, "╱")

    local value = vim.wo[win].fillchars
    assert.is_truthy(value:find("diff:╱", 1, true))
    assert.is_truthy(value:find("eob: ", 1, true))
    assert.is_truthy(value:find("vert:│", 1, true))
    -- window-local なので他へ漏れない
    assert.is_falsy(vim.o.fillchars:find("diff:", 1, true))

    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does nothing when the fillchar is disabled", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = 10,
      height = 5,
      row = 1,
      col = 1,
    })

    DiffMode.set_fill_char(win, "")
    assert.is_falsy(vim.wo[win].fillchars:find("diff:", 1, true))

    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
