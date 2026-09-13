-- unified表示のもと。狙いは「バッファに素のコードだけを置く」ことで、`+` / `-` が1つでも
-- 残るとその行はもうその言語として壊れていて、構文ハイライトが当たらない
local UnifiedLines = require("vibing.ui.patch_viewer.unified_lines")

local function kinds(rows)
  return vim.tbl_map(function(row)
    return row.kind
  end, rows)
end

local function texts(rows)
  return vim.tbl_map(function(row)
    return row.text
  end, rows)
end

describe("patch_viewer.unified_lines", function()
  local PATCH = table.concat({
    "diff --git a/lua/foo.lua b/lua/foo.lua",
    "index 1234567..89abcde 100644",
    "--- a/lua/foo.lua",
    "+++ b/lua/foo.lua",
    "@@ -10,3 +10,3 @@ function M.run()",
    "   local x = 1",
    "-  return x",
    "+  return x + 1",
    " end",
  }, "\n")

  it("strips the +/- column so the text is valid source again", function()
    local rows = UnifiedLines.build(PATCH)

    assert.same({ "hunk", "context", "del", "add", "context" }, kinds(rows))
    assert.same({
      "@@ -10,3 +10,3 @@ function M.run()",
      "  local x = 1",
      "  return x",
      "  return x + 1",
      "end",
    }, texts(rows))
  end)

  it("drops the headers whose content the Files panel and the title already show", function()
    local rows = UnifiedLines.build(PATCH)

    for _, row in ipairs(rows) do
      assert.is_falsy(row.text:match("^diff %-%-git"))
      assert.is_falsy(row.text:match("^index "))
      assert.is_falsy(row.text:match("^%+%+%+ "))
    end
  end)

  it("numbers deletions from the old file and everything else from the new one", function()
    local rows = UnifiedLines.build(PATCH)

    assert.is_nil(rows[1].lnum)
    assert.equals(10, rows[2].lnum)
    assert.equals(11, rows[3].lnum)
    assert.equals(11, rows[4].lnum)
    assert.equals(12, rows[5].lnum)
  end)

  it("marks the changed characters when the runs line up one to one", function()
    local rows = UnifiedLines.build(PATCH)

    assert.same({}, rows[3].char_ranges)
    assert.same({ { start_col = 10, end_col = 14 } }, rows[4].char_ranges)
  end)

  it("leaves the characters alone when the runs do not line up", function()
    local rows = UnifiedLines.build(table.concat({
      "@@ -1,1 +1,2 @@",
      "-one",
      "+uno",
      "+dos",
    }, "\n"))

    -- 1行消して2行足したのを上から突き合わせると、無関係な行どうしが濃く着く
    for _, row in ipairs(rows) do
      assert.is_nil(row.char_ranges)
    end
  end)

  it("reads `--- text` inside a hunk as a deletion, not as a file header", function()
    local rows = UnifiedLines.build(table.concat({
      "diff --git a/a.lua b/a.lua",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1,2 +1,1 @@",
      "--- comment",
      " keep",
    }, "\n"))

    -- `-- comment` を消した行は patch では `--- comment` になる。行の形だけで
    -- ヘッダと判定すると本文を1行取りこぼす
    assert.same({ "hunk", "del", "context" }, kinds(rows))
    assert.equals("-- comment", rows[2].text)
  end)

  it("keeps the headers that say what happened to the file", function()
    local rows = UnifiedLines.build(table.concat({
      "diff --git a/bin/logo.png b/bin/logo.png",
      "new file mode 100644",
      "index 0000000..1234567",
      "Binary files /dev/null and b/bin/logo.png differ",
    }, "\n"))

    assert.same({ "info", "info" }, kinds(rows))
    assert.same({
      "new file mode 100644",
      "Binary files /dev/null and b/bin/logo.png differ",
    }, texts(rows))
  end)

  it("handles an empty diff without producing a stray line", function()
    assert.same({}, UnifiedLines.build(nil))
    assert.same({}, UnifiedLines.build(""))
  end)
end)
