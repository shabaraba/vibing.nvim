-- `### Modified Files` はファイルを1行ずつ並べるのをやめ、1行のサマリになった。差分を見る
-- 導線は `gd`（patch_viewerのフロート）1本で、そこにファイル一覧があるため。
--
-- 固定したいのは、行が **必ず1行であること** と、件数が省略されないこと。件数が消えると
-- 「3件のうち3件見た」が分からなくなる。
local SendMessage = require("vibing.application.chat.send_message")

describe("send_message._summary_line", function()
  it("names a single file without pluralising", function()
    assert.equals("1 file changed: README.md", SendMessage._summary_line({ "README.md" }))
  end)

  it("names every file while they fit", function()
    assert.equals(
      "3 files changed: a.lua, b.lua, c.lua",
      SendMessage._summary_line({ "a.lua", "b.lua", "c.lua" })
    )
  end)

  it("keeps the total when it stops naming files", function()
    assert.equals(
      "6 files changed: a.lua, b.lua, c.lua, +3 more",
      SendMessage._summary_line({ "a.lua", "b.lua", "c.lua", "d.lua", "e.lua", "f.lua" })
    )
  end)

  it("stays on one line whatever it is given", function()
    local many = {}
    for i = 1, 80 do
      table.insert(many, string.format("lua/vibing/mod_%d.lua", i))
    end
    local line = SendMessage._summary_line(many)

    assert.is_nil(line:find("\n", 1, true))
    assert.is_truthy(line:find("80 files changed", 1, true))
  end)
end)
