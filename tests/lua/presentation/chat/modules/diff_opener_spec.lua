-- diff_opener.lua は `gd` の入口。ここで固定したいのは、どのビューアが選ばれるかの分岐だけ。
-- mini.diff は任意依存なので、その有無はスタブで作る。
local DiffOpener = require("vibing.presentation.chat.modules.diff_opener")
local Config = require("vibing.config")

describe("diff_opener", function()
  local saved_viewer
  local saved_mini

  local function with_mini(present)
    package.loaded["mini.diff"] = present and { gen_source = {} } or nil
  end

  before_each(function()
    if not Config.options then
      Config.setup({})
    end
    Config.options.diff = Config.options.diff or {}
    saved_viewer = Config.options.diff.viewer
    saved_mini = package.loaded["mini.diff"]
  end)

  after_each(function()
    Config.options.diff.viewer = saved_viewer
    package.loaded["mini.diff"] = saved_mini
  end)

  describe("resolve_viewer", function()
    it('uses the float even when "auto" and mini.diff is installed', function()
      -- 既定はフロート。mini.diffが入っているだけでインラインに倒れると、ファイル一覧も
      -- side-by-sideも見られないまま `view.style` 任せの表示になる
      Config.options.diff.viewer = "auto"
      with_mini(true)
      assert.equals("patch", DiffOpener.resolve_viewer())
    end)

    it('uses mini.diff only when it is asked for by name', function()
      Config.options.diff.viewer = "mini"
      with_mini(true)
      assert.equals("mini", DiffOpener.resolve_viewer())
    end)

    it('falls back to the patch viewer when "auto" and it is not installed', function()
      Config.options.diff.viewer = "auto"
      with_mini(false)
      assert.equals("patch", DiffOpener.resolve_viewer())
    end)

    it('never uses mini.diff when "patch" is set, even if installed', function()
      Config.options.diff.viewer = "patch"
      with_mini(true)
      assert.equals("patch", DiffOpener.resolve_viewer())
    end)

    it('falls back rather than failing when "mini" is set but not installed', function()
      Config.options.diff.viewer = "mini"
      with_mini(false)
      -- 設定ミスは警告される（`notify.warn_once`）が、`gd` は必ず何かを表示する
      assert.equals("patch", DiffOpener.resolve_viewer())
    end)

    it('defaults to "auto" behaviour when the option is absent', function()
      Config.options.diff.viewer = nil
      with_mini(true)
      assert.equals("patch", DiffOpener.resolve_viewer())
    end)
  end)

  describe("_show_inline", function()
    it("declines a patch file that does not exist", function()
      assert.is_false(DiffOpener._show_inline("/nope/missing.patch", "a.lua"))
    end)

    it("declines a patch with no base header", function()
      -- baseヘッダの無いpatchは削除されたmote統合が書いたもので、逆適用できる自己完結した
      -- diffではない。patch_viewerなら表示だけはできるので、falseを返して譲る
      local path = vim.fn.tempname() .. ".patch"
      vim.fn.writefile({ "diff --git a/a.lua b/a.lua", "@@ -1 +1 @@", "-x", "+y" }, path)

      local shown = DiffOpener._show_inline(path, "a.lua")
      vim.fn.delete(path)

      assert.is_false(shown)
    end)
  end)
end)
