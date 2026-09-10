-- 閉じフェンスの直後に文章が続く行を割る正規化のテスト。
-- 割りすぎるとブロック内に書かれた markdown の例（``` を含む本文）を書き換えてしまうので、
-- 「割る」側と同じだけ「割らない」側を押さえる。

describe("markdown_fence.normalize", function()
  local MarkdownFence = require("vibing.core.utils.markdown_fence")

  --- @param lines string[]
  --- @return string[]
  local function normalize(lines)
    return (MarkdownFence.normalize(lines))
  end

  it("splits prose that follows a closing fence", function()
    local result = normalize({ "```lua", "local x = 1", "```この続きは本文です" })

    assert.same({ "```lua", "local x = 1", "```", "この続きは本文です" }, result)
  end)

  it("splits an English sentence that follows a closing fence", function()
    local result = normalize({ "```", "code", "``` and then we run it" })

    assert.same({ "```", "code", "```", "and then we run it" }, result)
  end)

  it("leaves a language-name-looking word alone", function()
    -- ブロック内の "```json" は CommonMark でも閉じフェンスではなく本文。ここで割ると
    -- markdown を markdown で説明している入れ子の例が壊れる
    local input = { "````markdown", "```json", '{ "a": 1 }', "```", "````" }

    assert.same(input, normalize(input))
  end)

  it("leaves a proper closing fence alone", function()
    local input = { "```lua", "local x = 1", "```", "本文" }

    assert.same(input, normalize(input))
  end)

  it("leaves an opening fence with an info string alone", function()
    local input = { "本文", "```lua", "local x = 1" }

    assert.same(input, normalize(input))
  end)

  it("does not treat a shorter marker run as a closing fence", function()
    local input = { "````", "``` still inside the block", "````" }

    assert.same(input, normalize(input))
  end)

  it("handles tilde fences and up to three spaces of indent", function()
    local result = normalize({ "   ~~~text", "body", "   ~~~あとがき" })

    assert.same({ "   ~~~text", "body", "   ~~~", "あとがき" }, result)
  end)

  it("keeps the split text off the indented-code-block threshold", function()
    local result = normalize({ "```", "code", "```      説明" })

    assert.same({ "```", "code", "```", "説明" }, result)
  end)

  it("stops an unfinished fence at a message header", function()
    -- スキャナと同じ扱い。ヘッダーで打ち切らないと、次のターンの開始フェンスを
    -- 「閉じフェンス」と読んでしまう
    local result = normalize({
      "```lua",
      "local x = 1",
      "## Assistant <!-- 2026-09-10 10:00:00 -->",
      "```これは新しいブロックの開始",
    })

    assert.same({
      "```lua",
      "local x = 1",
      "## Assistant <!-- 2026-09-10 10:00:00 -->",
      "```これは新しいブロックの開始",
    }, result)
  end)

  it("reports the open fence so the next call can continue", function()
    local _, state = MarkdownFence.normalize({ "```lua", "local x = 1" })
    assert.same({ marker = "`", length = 3 }, state)

    local result = normalize({ "```続き" })
    assert.same({ "```続き" }, result, "状態を渡さなければブロックの外なので割らない")

    local continued = MarkdownFence.normalize({ "```続き" }, state)
    assert.same({ "```", "続き" }, continued)
  end)
end)

describe("markdown_fence.scan", function()
  local MarkdownFence = require("vibing.core.utils.markdown_fence")

  it("returns the state without rewriting anything", function()
    assert.same({ marker = "`", length = 3 }, MarkdownFence.scan({ "```lua", "local x = 1" }))
    assert.is_nil(MarkdownFence.scan({ "```lua", "local x = 1", "```" }))
  end)

  it("scans only the requested range", function()
    local lines = { "```lua", "local x = 1", "```", "本文" }

    assert.same({ marker = "`", length = 3 }, MarkdownFence.scan(lines, nil, 1, 2))
    assert.is_nil(MarkdownFence.scan(lines, nil, 1, 3))
  end)
end)
