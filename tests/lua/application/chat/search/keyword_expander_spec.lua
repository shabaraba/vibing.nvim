local KeywordExpander = require("vibing.application.chat.search.keyword_expander")

describe("chat search keyword expander", function()
  it("takes one keyword per line", function()
    assert.are.same({ "webfetch", "URL表示" }, KeywordExpander.parse("webfetch\nURL表示"))
  end)

  it("strips bullets, numbering and quotes", function()
    assert.are.same({ "webfetch", "URL表示", "閲覧したurl" }, KeywordExpander.parse('- webfetch\n1. "URL表示"\n* 閲覧したurl'))
  end)

  it("drops duplicates that differ only in case", function()
    assert.are.same({ "WebFetch" }, KeywordExpander.parse("WebFetch\nwebfetch"))
  end)

  it("keeps at most four keywords", function()
    assert.are.equal(4, #KeywordExpander.parse("a\nb\nc\nd\ne\nf"))
  end)

  it("returns nothing for an empty response", function()
    assert.are.same({}, KeywordExpander.parse(""))
    assert.are.same({}, KeywordExpander.parse(nil))
  end)
end)
