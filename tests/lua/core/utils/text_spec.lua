-- 切り詰めは **表示幅** で数える。文字数で数えると、CJKなど幅2の文字が混じるパスで
-- 枠からはみ出したり、末尾を残す側では開始位置が負になってVimの「末尾から数える」挙動に化ける
local Truncate = require("vibing.core.utils.text")

describe("text.truncate", function()
  it("leaves a string that already fits untouched", function()
    assert.equals("short.lua", Truncate.head("short.lua", 20))
    assert.equals("short.lua", Truncate.tail("short.lua", 20))
  end)

  it("keeps an ASCII name inside the width and marks it", function()
    assert.equals("abcd…", Truncate.head("abcdefghij", 5))
    assert.equals("…ghij", Truncate.tail("abcdefghij", 5))
  end)

  it("never exceeds the width on a name of wide characters", function()
    local name = "日本語のとても長いファイル名.lua"

    for width = 2, 30 do
      assert.is_true(vim.fn.strwidth(Truncate.head(name, width)) <= width)
      assert.is_true(vim.fn.strwidth(Truncate.tail(name, width)) <= width)
    end
  end)

  it("keeps the end of a path so the file name survives", function()
    local result = Truncate.tail("lua/vibing/日本語/とても長い名前.lua", 12)

    assert.equals("…", result:sub(1, #"…"))
    assert.is_true(vim.endswith(result, ".lua"))
  end)

  it("does not split a wide character in half", function()
    -- 幅2の文字は入るか入らないかのどちらか。半分だけ残すとバイト列が壊れる
    local result = Truncate.head("あいうえお", 5)

    assert.equals("あい…", result)
  end)
end)

describe("text.wrap", function()
  it("leaves a line that already fits as one line", function()
    assert.same({ "short note" }, Truncate.wrap("short note", 20))
  end)

  it("returns one empty line for an empty string", function()
    assert.same({ "" }, Truncate.wrap("", 20))
  end)

  it("breaks an English sentence at spaces, not mid-word", function()
    local lines = Truncate.wrap("this handle leaks on every error path", 16)

    assert.same({ "this handle", "leaks on every", "error path" }, lines)
  end)

  it("never leaves a line wider than the width, including CJK", function()
    local text = "この関数はエラー経路でハンドルを解放していないため、リークします"

    for width = 4, 40 do
      for _, line in ipairs(Truncate.wrap(text, width)) do
        assert.is_true(vim.fn.strwidth(line) <= width)
      end
    end
  end)

  it("splits a word that cannot fit at all rather than overflowing", function()
    local lines = Truncate.wrap("supercalifragilistic", 6)

    assert.same({ "superc", "alifra", "gilist", "ic" }, lines)
  end)

  it("drops the space a wrap happened at instead of indenting the next line", function()
    local lines = Truncate.wrap("alpha beta", 6)

    assert.same({ "alpha", "beta" }, lines)
  end)

  it("keeps every character of the input", function()
    local text = "a longer note about the retry budget, 日本語混じり, and more"

    assert.equals(text:gsub("%s", ""), table.concat(Truncate.wrap(text, 13)):gsub("%s", ""))
  end)
end)
