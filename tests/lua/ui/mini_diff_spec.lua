-- mini_diff.lua は `gd` のインライン表示。mini.diff は **任意依存** なので、テストは本物を
-- 要求せずスタブで代用する（CI にも開発者の環境にも入っているとは限らない）。
--
-- ここで固定したいのは2つ:
--   1. patch内の生パスの解決 — base_dir が Neovim の cwd と一致しない（worktree、working_dir）
--      環境でも、一時ツリーにファイルを置く位置を間違えないこと
--   2. `_attach` の呼び出し順 — disable → minidiff_config → set_ref_text。この順でないと
--      sourceが張り替わらず、次の `.git/index` 変更で参照テキストが黙って消える
local MiniDiff = require("vibing.ui.mini_diff")

describe("mini_diff", function()
  describe("resolve_rel_path", function()
    local patch = table.concat({
      "# vibing-request-diff base: /repo",
      "diff --git a/lua/vibing/init.lua b/lua/vibing/init.lua",
      "index 111..222 100644",
      "--- a/lua/vibing/init.lua",
      "+++ b/lua/vibing/init.lua",
      "@@ -1 +1 @@",
      "-old",
      "+new",
      "diff --git a/doc/vibing.txt b/doc/vibing.txt",
      "index 333..444 100644",
    }, "\n")

    it("matches an absolute path by its path-boundary suffix", function()
      assert.equals(
        "lua/vibing/init.lua",
        MiniDiff._resolve_rel_path(patch, "/repo/lua/vibing/init.lua")
      )
    end)

    it("matches the patch-relative path as written", function()
      assert.equals("doc/vibing.txt", MiniDiff._resolve_rel_path(patch, "doc/vibing.txt"))
    end)

    it("does not match on a bare substring", function()
      -- "init.lua" は patch 内のパスの部分文字列だが、パス境界で切れていないので別物
      assert.is_nil(MiniDiff._resolve_rel_path(patch, "/repo/other/xinit.lua"))
    end)

    it("returns nil for a file the patch does not contain", function()
      assert.is_nil(MiniDiff._resolve_rel_path(patch, "/repo/README.md"))
    end)
  end)

  describe("_attach", function()
    local buf

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "after" })
    end)

    after_each(function()
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end)

    ---呼び出し順を記録するmini.diffのスタブ
    local function stub(calls)
      return {
        gen_source = {
          none = function()
            return { name = "none", attach = function() end }
          end,
        },
        disable = function()
          table.insert(calls, "disable")
        end,
        set_ref_text = function()
          table.insert(calls, "set_ref_text")
        end,
        get_buf_data = function()
          return { overlay = false }
        end,
        toggle_overlay = function()
          table.insert(calls, "toggle_overlay")
        end,
      }
    end

    it("disables the buffer before setting reference text", function()
      local calls = {}
      MiniDiff._attach(stub(calls), buf, { "before" })

      -- sourceのattachはenable時にしか起きないので、disableが先でなければ
      -- `minidiff_config` に書いた `source = none` は効かない
      assert.equals("disable", calls[1])
      assert.equals("set_ref_text", calls[2])
    end)

    it("pins the buffer source to none", function()
      MiniDiff._attach(stub({}), buf, { "before" })

      local config = vim.b[buf].minidiff_config
      assert.is_table(config)
      assert.equals("none", config.source.name)
    end)

    it("turns the overlay on so deleted lines are visible", function()
      local calls = {}
      MiniDiff._attach(stub(calls), buf, { "before" })

      assert.is_truthy(vim.tbl_contains(calls, "toggle_overlay"))
    end)

    it("records the buffer so VibingDiffClear can find it", function()
      MiniDiff._attach(stub({}), buf, { "before" })

      assert.is_truthy(vim.tbl_contains(MiniDiff._marked(), buf))
    end)
  end)

  describe("is_available", function()
    it("is false when mini.diff is not installed", function()
      local saved = package.loaded["mini.diff"]
      package.loaded["mini.diff"] = nil
      -- スタブすら無い状態。テスト環境の runtimepath に mini.diff は無い
      local available = MiniDiff.is_available()
      package.loaded["mini.diff"] = saved

      assert.is_false(available)
    end)

    it("is true once mini.diff resolves", function()
      local saved = package.loaded["mini.diff"]
      package.loaded["mini.diff"] = { gen_source = {} }
      local available = MiniDiff.is_available()
      package.loaded["mini.diff"] = saved

      assert.is_true(available)
    end)
  end)
end)
