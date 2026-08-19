-- Tests for vibing.presentation.chat.modules.keymap_handler.find_url_on_line
--
-- gx (open_url) は行内の URL を抽出して vim.ui.open に渡す。Markdown 装飾や括弧で
-- 囲まれた URL の閉じ記号を取り込むと 404 になる一方、URL 自体に括弧・アスタリスク・
-- IPv6 のブラケットを含む正当な URL は保持しなければならない。両立を回帰で守る。

local KeymapHandler = require("vibing.presentation.chat.modules.keymap_handler")

describe("keymap_handler.find_url_on_line", function()
  -- カーソルは URL 上（先頭付近）に置く前提。col は URL の "h" にほぼ重なる位置で十分。
  local function url_at(line)
    local col = line:find("https?://") or 1
    return KeymapHandler.find_url_on_line(line, col)
  end

  describe("strips Markdown decorations and enclosing brackets", function()
    local cases = {
      {
        name = "bold-wrapped URL",
        line = "**PR: https://github.com/kintone/llm-wiki/pull/28**",
        want = "https://github.com/kintone/llm-wiki/pull/28",
      },
      {
        name = "inline-code-wrapped URL",
        line = "`https://github.com/kintone/llm-wiki/pull/28`",
        want = "https://github.com/kintone/llm-wiki/pull/28",
      },
      {
        name = "markdown link target",
        line = "[docs](https://example.com/foo/bar)",
        want = "https://example.com/foo/bar",
      },
      {
        name = "parenthesized URL",
        line = "see (https://example.com/a) here",
        want = "https://example.com/a",
      },
      {
        name = "angle-bracket-wrapped URL",
        line = "<https://example.com/x>",
        want = "https://example.com/x",
      },
      {
        name = "brace-wrapped URL",
        line = "text {https://example.com/y} end",
        want = "https://example.com/y",
      },
      {
        name = "trailing sentence punctuation",
        line = "visit https://example.com/path.",
        want = "https://example.com/path",
      },
      {
        name = "trailing closer then punctuation",
        line = "(https://example.com/path).",
        want = "https://example.com/path",
      },
    }

    for _, c in ipairs(cases) do
      it(c.name, function()
        assert.equals(c.want, url_at(c.line))
      end)
    end
  end)

  describe("preserves valid URL characters", function()
    local cases = {
      {
        name = "IPv6 host in brackets",
        line = "https://[2001:db8::1]/",
        want = "https://[2001:db8::1]/",
      },
      {
        name = "balanced parentheses in path",
        line = "https://en.wikipedia.org/wiki/Foo_(disambiguation)",
        want = "https://en.wikipedia.org/wiki/Foo_(disambiguation)",
      },
      {
        name = "parentheses mid-path",
        line = "https://example.com/a(b)c",
        want = "https://example.com/a(b)c",
      },
      {
        name = "asterisk mid-path",
        line = "https://example.com/a*b",
        want = "https://example.com/a*b",
      },
    }

    for _, c in ipairs(cases) do
      it(c.name, function()
        assert.equals(c.want, url_at(c.line))
      end)
    end
  end)

  it("returns the URL under the cursor when several are on the line", function()
    local line = "a https://example.com/one b https://example.com/two c"
    local col = line:find("two") -- カーソルは2つ目の URL 上
    assert.equals("https://example.com/two", KeymapHandler.find_url_on_line(line, col))
  end)

  it("returns nil when the line has no URL", function()
    assert.is_nil(KeymapHandler.find_url_on_line("just some plain text", 3))
  end)

  it("returns nil when the cursor is far from any URL", function()
    -- 行末付近にカーソル。URL は先頭で max_dist(10) を大きく超える。
    local line = "https://example.com/x" .. string.rep(" ", 40) .. "tail"
    assert.is_nil(KeymapHandler.find_url_on_line(line, #line))
  end)
end)
