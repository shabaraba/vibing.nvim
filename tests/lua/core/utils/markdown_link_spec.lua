-- markdown_link.lua は `gx` / `gf` / `gd` が共有する「カーソルはリンク記法の中か」の唯一の判定。
-- ラベルの上では `<cfile>` がラベルの文字列を拾うので、この判定が無いと gf/gd は飛べない。
local MarkdownLink = require("vibing.core.utils.markdown_link")

describe("markdown_link.find_at", function()
  it("resolves the destination from anywhere in the notation", function()
    local line = "see [the module docs](handbook/configuration.md) for details"
    -- `find` は2値を返す。末尾だけ括弧で1値に落とさないと終了位置が紛れ込む
    local positions = {
      line:find("%["),
      line:find("module"),
      line:find("%]%("),
      line:find("handbook"),
      (line:find("%) for")),
    }
    for _, col in ipairs(positions) do
      assert.equals("handbook/configuration.md", MarkdownLink.find_at(line, col))
    end
  end)

  it("returns nil outside the notation", function()
    local line = "see [the docs](a.md) for details"
    assert.is_nil(MarkdownLink.find_at(line, 1))
    assert.is_nil(MarkdownLink.find_at(line, line:find("for details")))
  end)

  it("picks the link the cursor is in when several are on the line", function()
    local line = "[first label](one.md) and [second label](two.md)"
    assert.equals("one.md", MarkdownLink.find_at(line, line:find("first")))
    assert.equals("two.md", MarkdownLink.find_at(line, line:find("second")))
    -- リンクの間は記法の外
    assert.is_nil(MarkdownLink.find_at(line, line:find(" and ") + 2))
  end)

  it("supports nested brackets in the label", function()
    local line = "[outer [inner] label](nested.md)"
    assert.equals("nested.md", MarkdownLink.find_at(line, line:find("inner")))
  end)

  it("includes the image bang in the notation", function()
    local line = "![alt text](shot.png)"
    assert.equals("shot.png", MarkdownLink.find_at(line, 1))
  end)

  it("drops a title and angle brackets", function()
    assert.equals("a.md", MarkdownLink.find_at('[x](a.md "the title")', 2))
    assert.equals("a b.md", MarkdownLink.find_at("[x](<a b.md>)", 2))
    assert.equals("https://example.com/a_(b)", MarkdownLink.find_at('[x](<https://example.com/a_(b)> "t")', 2))
  end)

  it("declines a reference link, whose target is not on the line", function()
    -- `[label] (dest)` も同様。CommonMark ではリンク先は `]` の直後に続く必要がある
    assert.is_nil(MarkdownLink.find_at("[label][ref]", 3))
    assert.is_nil(MarkdownLink.find_at("[label] (a.md)", 3))
  end)

  it("declines an empty destination", function()
    assert.is_nil(MarkdownLink.find_at("[label]()", 3))
  end)

  it("stops scanning once the links start past the cursor", function()
    -- 左から進むので、カーソルより後ろのリンクは調べるまでもない
    local line = "text [a](one.md) [b](two.md)"
    assert.is_nil(MarkdownLink.find_at(line, 1))
  end)
end)

-- リンク先の種類を各キーマップが書き分けると、どのキーも取らない隙間ができる。
-- `mailto:` が `gx` からも `gf` からも漏れていたのがそれ。
describe("markdown_link.classify", function()
  it("calls a scheme'd destination a url", function()
    for _, dest in ipairs({ "https://example.com", "http://a/b", "ftp://host/x", "mailto:a@b.com" }) do
      assert.equals("url", MarkdownLink.classify(dest))
    end
  end)

  it("calls a leading # an anchor", function()
    assert.equals("anchor", MarkdownLink.classify("#invariants"))
  end)

  it("calls everything else a path", function()
    for _, dest in ipairs({ "a.md", "./a.md", "/abs/a.md", "~/a.md", "a.lua:42", "doc.md#section" }) do
      assert.equals("path", MarkdownLink.classify(dest))
    end
  end)
end)
