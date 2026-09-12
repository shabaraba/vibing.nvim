-- ファイル一覧に出す `A` / `D` / `+N -M`。`+++ b/path` と `--- a/path` はヘッダであって
-- 変更行ではないので、素朴に先頭1文字で数えると毎ファイル +1 -1 ずれる。
local parser = require("vibing.ui.patch_viewer.parser")

local PATCH = table.concat({
  "# vibing-request-diff base: /tmp/repo",
  "diff --git a/kept.lua b/kept.lua",
  "index 111..222 100644",
  "--- a/kept.lua",
  "+++ b/kept.lua",
  "@@ -1,3 +1,4 @@",
  " context",
  "-gone",
  "+new one",
  "+new two",
  " tail",
  "diff --git a/added.lua b/added.lua",
  "new file mode 100644",
  "index 000..333",
  "--- /dev/null",
  "+++ b/added.lua",
  "@@ -0,0 +1,1 @@",
  "+hello",
  "diff --git a/gone.lua b/gone.lua",
  "deleted file mode 100644",
  "index 444..000",
  "--- a/gone.lua",
  "+++ /dev/null",
  "@@ -1,2 +0,0 @@",
  "-one",
  "-two",
}, "\n")

describe("parser.file_stats", function()
  it("counts changed lines without counting the +++/--- headers", function()
    local stats = parser.file_stats(PATCH, "kept.lua")

    assert.equals("M", stats.status)
    assert.equals(2, stats.added)
    assert.equals(1, stats.removed)
  end)

  it("reports an added file", function()
    local stats = parser.file_stats(PATCH, "added.lua")

    assert.equals("A", stats.status)
    assert.equals(1, stats.added)
    assert.equals(0, stats.removed)
  end)

  it("reports a deleted file", function()
    local stats = parser.file_stats(PATCH, "gone.lua")

    assert.equals("D", stats.status)
    assert.equals(0, stats.added)
    assert.equals(2, stats.removed)
  end)

  it("falls back to zero for a file the patch does not mention", function()
    local stats = parser.file_stats(PATCH, "absent.lua")

    assert.equals("M", stats.status)
    assert.equals(0, stats.added)
    assert.equals(0, stats.removed)
  end)

  it("keeps all_stats in step with the file list", function()
    local files = parser.extract_files(PATCH)
    local stats = parser.all_stats(PATCH, files)

    assert.equals(#files, #stats)
    for i, file in ipairs(files) do
      assert.same(parser.file_stats(PATCH, file), stats[i])
    end
  end)
end)
