-- 文字単位の差分範囲。side-by-side は `inline:char` から同じものを貰っているので、
-- ここが黙って空を返すと unified だけ「行は着いているが、どこが変わったか分からない」になる
local CharDiff = require("vibing.ui.patch_viewer.char_diff")

describe("patch_viewer.char_diff", function()
  it("points at the inserted part only, on the side that has it", function()
    local del, add = CharDiff.ranges("  return x", "  return x + 1")

    -- 消えた文字は無いので、左に濃くする場所は無い
    assert.same({}, del)
    assert.same({ { start_col = 10, end_col = 14 } }, add)
  end)

  it("points at the replaced character on both sides", function()
    local del, add = CharDiff.ranges("foo bar", "foo baz")

    assert.same({ { start_col = 6, end_col = 7 } }, del)
    assert.same({ { start_col = 6, end_col = 7 } }, add)
  end)

  it("returns byte ranges, not character counts", function()
    local del, add = CharDiff.ranges("あいう", "あXう")

    -- 素朴に文字数で数えると 1..2 になり、マルチバイトの途中を指して色が崩れる
    assert.same({ { start_col = 3, end_col = 6 } }, del)
    assert.same({ { start_col = 3, end_col = 4 } }, add)
  end)

  it("gives up on a line long enough to be worth not diffing", function()
    local del, add = CharDiff.ranges(string.rep("a", 900), string.rep("b", 900))

    assert.same({}, del)
    assert.same({}, add)
  end)

  it("gives up when one side is empty, since the whole line says it already", function()
    local del, add = CharDiff.ranges("", "added")

    assert.same({}, del)
    assert.same({}, add)
  end)
end)
