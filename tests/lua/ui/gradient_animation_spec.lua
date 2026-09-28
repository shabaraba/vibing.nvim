-- 承認・質問はターンを開いたまま答えを待つ（#778, #788）。グラデーションがターンの開始〜終了しか
-- 見ていないと、人間の番のあいだも「まだ動いている」表示が流れ続ける
local GradientAnimation = require("vibing.ui.gradient_animation")

local function number_hls(bufnr)
  local ns = vim.api.nvim_create_namespace("vibing_gradient_" .. bufnr)
  local hls = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
    table.insert(hls, mark[4].number_hl_group)
  end
  return hls
end

local function wait_for(pred)
  assert.is_true(vim.wait(1000, pred, 10), "condition was never met")
end

describe("gradient_animation waiting state", function()
  local bufnr

  before_each(function()
    require("vibing.config").setup({ ui = { gradient = { enabled = true, interval = 10 } } })
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b", "c" })
  end)

  after_each(function()
    GradientAnimation.stop(bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("paints every line number with the waiting group while a human is being waited for", function()
    local waiting = false
    GradientAnimation.start(bufnr, {
      is_waiting = function()
        return waiting
      end,
    })

    wait_for(function()
      return #number_hls(bufnr) == 3
    end)
    for _, hl in ipairs(number_hls(bufnr)) do
      assert.are_not.equal(GradientAnimation.WAITING_HL, hl)
    end
    assert.is_false(GradientAnimation.is_waiting(bufnr))

    waiting = true
    wait_for(function()
      return GradientAnimation.is_waiting(bufnr)
    end)
    assert.same({
      GradientAnimation.WAITING_HL,
      GradientAnimation.WAITING_HL,
      GradientAnimation.WAITING_HL,
    }, number_hls(bufnr))

    -- 答えが出たらターンはまだ続くので、グラデーションに戻る
    waiting = false
    wait_for(function()
      return not GradientAnimation.is_waiting(bufnr)
    end)
    for _, hl in ipairs(number_hls(bufnr)) do
      assert.are_not.equal(GradientAnimation.WAITING_HL, hl)
    end
  end)

  it("colors the waiting group with ui.gradient.waiting_color", function()
    require("vibing.config").setup({ ui = { gradient = { enabled = true, interval = 10, waiting_color = "#123456" } } })
    GradientAnimation.start(bufnr)

    assert.equal(0x123456, vim.api.nvim_get_hl(0, { name = GradientAnimation.WAITING_HL }).fg)
  end)

  it("keeps animating when the waiting predicate throws", function()
    GradientAnimation.start(bufnr, {
      is_waiting = function()
        error("boom")
      end,
    })

    wait_for(function()
      return #number_hls(bufnr) == 3
    end)
    assert.is_false(GradientAnimation.is_waiting(bufnr))
  end)
end)
