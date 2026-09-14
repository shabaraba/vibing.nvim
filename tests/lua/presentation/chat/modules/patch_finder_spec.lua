-- patch行は `<!-- patch: ... -->` という隠しコメントから素の `Patch: <path>` になった。
-- 保存済みのチャットは旧形式のまま残るので、両方読めることがこのモジュールの仕事。
local PatchFinder = require("vibing.presentation.chat.modules.patch_finder")

describe("patch_finder", function()
  local buf

  local function open(lines, row)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    return buf
  end

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  describe("parse_patch_line", function()
    it("reads the visible form", function()
      assert.equals("/tmp/a/.vibing/patches/x.patch", PatchFinder.parse_patch_line("Patch: /tmp/a/.vibing/patches/x.patch"))
    end)

    it("still reads the hidden form old chats were written with", function()
      assert.equals("/tmp/old.patch", PatchFinder.parse_patch_line("<!-- patch: /tmp/old.patch -->"))
    end)

    it("tolerates surrounding whitespace", function()
      assert.equals("/tmp/b.patch", PatchFinder.parse_patch_line("Patch:   /tmp/b.patch  "))
    end)

    it("reads a path that contains spaces", function()
      -- ワークスペース名やworktree名に空白が入ることはある。ここで切ると `gd` はそのターンの
      -- patchを見つけられず、黙ってHEAD差分に落ちる
      assert.equals(
        "/tmp/My Project/.vibing/patches/x.patch",
        PatchFinder.parse_patch_line("Patch: /tmp/My Project/.vibing/patches/x.patch")
      )
      assert.equals("/tmp/My Old/x.patch", PatchFinder.parse_patch_line("<!-- patch: /tmp/My Old/x.patch -->"))
    end)

    it("declines the one-line summary and a bare path", function()
      assert.is_nil(PatchFinder.parse_patch_line("3 files changed: a.lua, b.lua"))
      assert.is_nil(PatchFinder.parse_patch_line("lua/vibing/init.lua"))
      -- 文中の "Patch:" を拾わない
      assert.is_nil(PatchFinder.parse_patch_line("Patch: applied two files and then some"))
    end)
  end)

  describe("find_nearest_patch", function()
    it("finds the visible patch line from anywhere in the section", function()
      open({
        "## 2026-09-13 10:00:00 Assistant",
        "",
        "### Modified Files",
        "",
        "2 files changed: a.lua, b.lua",
        "",
        "Patch: /tmp/x.patch",
      }, 5)

      assert.equals("/tmp/x.patch", PatchFinder.find_nearest_patch(buf))
    end)

    it("finds the hidden patch line in an old chat", function()
      open({
        "### Modified Files",
        "",
        "lua/vibing/init.lua",
        "<!-- patch: /tmp/old.patch -->",
      }, 3)

      assert.equals("/tmp/old.patch", PatchFinder.find_nearest_patch(buf))
    end)

    it("returns nil outside a Modified Files section", function()
      open({
        "## 2026-09-13 10:00:00 Assistant",
        "",
        "ふつうの本文",
        "Patch: /tmp/x.patch",
      }, 3)

      assert.is_nil(PatchFinder.find_nearest_patch(buf))
    end)
  end)
end)
