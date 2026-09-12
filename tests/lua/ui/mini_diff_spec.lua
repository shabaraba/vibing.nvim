-- mini_diff.lua は `gd` のインライン表示。mini.diff は **任意依存** なので、テストは本物を
-- 要求せずスタブで代用する（CI にも開発者の環境にも入っているとは限らない）。
--
-- ここで固定したいのは3つ:
--   1. patch内の生パスの解決 — base_dir が Neovim の cwd と一致しない（worktree、working_dir）
--      環境でも、一時ツリーにファイルを置く位置を間違えないこと
--   2. `_attach` の呼び出し順 — disable → minidiff_config → enable。この順でないと
--      sourceが張り替わらず、次の `.git/index` 変更で参照テキストが黙って消える
--   3. 参照テキストが **source経由** で張られること。mini.diffは `:edit` のたびに
--      disable → 再enableするので、`set_ref_text` を直接呼ぶだけでは一度きりの表示になる
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

    ---呼び出し順を記録するmini.diffのスタブ。enable → sourceのattach → set_ref_text という
    ---本物の順序を再現する（`H.cache` に当たるのが `data`）
    local function stub(calls)
      local s = {}
      s.data = nil
      s.gen_source = {
        none = function()
          return { name = "none", attach = function() end }
        end,
      }
      s.disable = function()
        table.insert(calls, "disable")
        s.data = nil
      end
      s.enable = function(target)
        table.insert(calls, "enable")
        s.data = { overlay = false }
        if vim.b[target].minidiff_config.source.attach(target) == false then
          s.data = nil
        end
      end
      s.set_ref_text = function(_, text)
        table.insert(calls, "set_ref_text")
        s.data.ref_text = text
      end
      s.get_buf_data = function()
        return s.data
      end
      s.toggle_overlay = function()
        table.insert(calls, "toggle_overlay")
        s.data.overlay = not s.data.overlay
      end
      return s
    end

    it("disables the buffer before enabling it with the vibing source", function()
      local calls = {}
      MiniDiff._attach(stub(calls), buf, { "before" })

      -- sourceのattachはenable時にしか起きないので、disableが先でなければ
      -- `minidiff_config` に書いた source は効かない
      assert.equals("disable", calls[1])
      assert.equals("enable", calls[2])
      assert.equals("set_ref_text", calls[3])
    end)

    it("pins the buffer source to vibing's own", function()
      MiniDiff._attach(stub({}), buf, { "before" })

      local config = vim.b[buf].minidiff_config
      assert.is_table(config)
      assert.equals("vibing", config.source.name)
    end)

    it("restores the reference text when mini.diff re-enables the buffer", function()
      -- `:edit` は on_detach → disable → auto-enable を起こす。参照テキストがsourceから
      -- 戻らないと、ファイルを開き直しただけでターンの差分が消える
      local calls = {}
      local diff = stub(calls)
      MiniDiff._attach(diff, buf, { "before" })

      diff.disable(buf)
      diff.enable(buf)

      assert.is_table(diff.get_buf_data(buf))
      assert.same({ "before" }, diff.get_buf_data(buf).ref_text)
    end)

    it("declines to attach once the buffer has been cleared", function()
      local diff = stub({})
      MiniDiff._attach(diff, buf, { "before" })
      local source = vim.b[buf].minidiff_config.source

      MiniDiff.clear(buf)

      -- `:VibingDiffClear` 後に auto-enable が走っても、消したはずの差分が戻らないこと
      assert.is_false(source.attach(buf))
      assert.is_nil(vim.b[buf].minidiff_config)
    end)

    it("turns the overlay on so deleted lines are visible", function()
      local calls = {}
      MiniDiff._attach(stub(calls), buf, { "before" })

      assert.is_truthy(vim.tbl_contains(calls, "toggle_overlay"))
    end)

    it("reports failure when mini.diff refuses the buffer", function()
      -- `vim.b.minidiff_disable` のケース。ここでtrueを返すと、呼び出し側は何も映って
      -- いないのにフォールバックしない
      local diff = stub({})
      diff.enable = function() end

      assert.is_false(MiniDiff._attach(diff, buf, { "before" }))
      assert.is_falsy(vim.tbl_contains(MiniDiff._marked(), buf))
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
