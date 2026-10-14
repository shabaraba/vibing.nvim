-- インストール済みプラグインの2つの配置を、1か所で読み解けているかだけを固定する。
-- `cache/` 側はプラグイン名がリビジョンの1つ上なので、basename をそのまま使うと名前がハッシュに
-- なり、`plugin:skill` の照合が永久に外れる（しかも静かに）。
--
-- 一覧はセッション中キャッシュされる。`:VibingReloadCommands` で捨てられなければ、
-- 入れたばかりのプラグインは再起動まで見えない。

local InstalledPlugins = require("vibing.infrastructure.plugins.installed_plugins")
local Fs = require("vibing.core.utils.fs")

describe("installed_plugins.roots", function()
  local base
  local saved_home

  -- モジュールと同じ `~` 展開を通す（macOSでは /var が /private/var になる）
  local function plugins_dir()
    return vim.fn.expand("~/.claude/plugins")
  end

  before_each(function()
    base = vim.fn.tempname()
    Fs.ensure_dir(base)
    saved_home = vim.env.HOME
    vim.env.HOME = base
    InstalledPlugins.clear_cache()
  end)

  after_each(function()
    vim.env.HOME = saved_home
    InstalledPlugins.clear_cache()
    vim.fn.delete(base, "rf")
  end)

  it("reads a plugin name out of each of the two layouts", function()
    Fs.ensure_dir(plugins_dir() .. "/marketplaces/some-market/plugins/from-market")
    Fs.ensure_dir(plugins_dir() .. "/cache/some-market/from-cache/abc123")

    local by_name = {}
    for _, root in ipairs(InstalledPlugins.roots()) do
      by_name[root.name] = root.path
    end

    assert.equals(plugins_dir() .. "/marketplaces/some-market/plugins/from-market", by_name["from-market"])
    -- リビジョンディレクトリではなく、その1つ上がプラグイン名
    assert.equals(plugins_dir() .. "/cache/some-market/from-cache/abc123", by_name["from-cache"])
    assert.is_nil(by_name["abc123"])
  end)

  it("answers with an empty list when nothing is installed", function()
    assert.same({}, InstalledPlugins.roots())
  end)

  it("keeps the list until it is cleared", function()
    assert.same({}, InstalledPlugins.roots())

    Fs.ensure_dir(plugins_dir() .. "/marketplaces/m/plugins/late-arrival")
    assert.same({}, InstalledPlugins.roots())

    InstalledPlugins.clear_cache()
    assert.equals("late-arrival", InstalledPlugins.roots()[1].name)
  end)
end)
