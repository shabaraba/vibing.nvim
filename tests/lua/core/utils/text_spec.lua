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
