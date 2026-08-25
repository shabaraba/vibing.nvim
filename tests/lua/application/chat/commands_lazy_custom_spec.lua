-- カスタムコマンドが setup() ではなく初回利用時にスキャンされることを固定する。
-- スキャンは .claude/commands/*.md を全文読み込みする同期I/Oで、起動時間の約4割を占めていた。
-- 「起動時には呼ばれない」ことと「使う直前には必ず呼ばれる」ことの両方が壊れやすいので、
-- 呼び出し回数そのものを見る。

describe("commands custom command lazy loading", function()
  local Commands
  local scan_count

  -- このspecは package.loaded を3つ差し替える。PlenaryBustedDirectory はspecファイルごとに
  -- 別のnvimを起動するので他ファイルには漏れないが、それはこのファイルの外の都合であって
  -- ここが保証していることではない。元の値を持って帰る。
  local MOCKED_MODULES = {
    "vibing.application.chat.commands",
    "vibing.application.chat.custom_commands",
    "vibing.core.utils.notify",
  }
  local original_loaded

  local function fake_custom_commands(commands)
    scan_count = 0
    package.loaded["vibing.application.chat.custom_commands"] = {
      get_all = function()
        scan_count = scan_count + 1
        return commands
      end,
      clear_cache = function() end,
    }
  end

  before_each(function()
    original_loaded = {}
    for _, name in ipairs(MOCKED_MODULES) do
      original_loaded[name] = package.loaded[name]
    end

    package.loaded["vibing.application.chat.commands"] = nil
    package.loaded["vibing.core.utils.notify"] = {
      error = function() end,
      warn = function() end,
      info = function() end,
    }

    fake_custom_commands({
      {
        name = "mycmd",
        description = "my custom command",
        source = "project",
        file_path = "/tmp/mycmd.md",
        content = "do the thing",
      },
    })

    Commands = require("vibing.application.chat.commands")
    Commands.commands = {}
    Commands.custom_commands = {}
  end)

  after_each(function()
    for _, name in ipairs(MOCKED_MODULES) do
      package.loaded[name] = original_loaded[name]
    end
  end)

  it("does not scan the disk just because the module was loaded", function()
    assert.equals(0, scan_count)
    assert.is_nil(Commands.custom_commands["mycmd"])
  end)

  it("scans on the first list_all() and registers what it found", function()
    local all = Commands.list_all()

    assert.equals(1, scan_count)
    assert.is_not_nil(all["mycmd"])
    assert.equals("my custom command", all["mycmd"].description)
  end)

  it("scans on the first execute() of an unknown command", function()
    local handled, expanded = Commands.execute("/mycmd", nil)

    assert.equals(1, scan_count)
    assert.is_true(handled)
    assert.equals("do the thing", expanded)
  end)

  it("scans only once across repeated use", function()
    Commands.list_all()
    Commands.list_all()
    Commands.execute("/mycmd", nil)

    assert.equals(1, scan_count)
  end)

  it("does not rescan after a scan that found nothing", function()
    -- 失敗/空振りのたびに再スキャンすると、補完のキー入力ごとに数十msのI/Oが走る。
    fake_custom_commands({})
    package.loaded["vibing.application.chat.commands"] = nil
    Commands = require("vibing.application.chat.commands")
    Commands.commands = {}
    Commands.custom_commands = {}

    Commands.execute("/nope", nil)
    Commands.execute("/nope", nil)
    Commands.list_all()

    assert.equals(1, scan_count)
  end)

  it("reload_custom() rescans and drops commands that no longer exist", function()
    Commands.list_all()
    assert.equals(1, scan_count)

    fake_custom_commands({
      { name = "other", description = "other", source = "project", file_path = "/tmp/o.md", content = "x" },
    })

    Commands.reload_custom()

    assert.equals(1, scan_count) -- fake を差し替えたのでカウンタもリセットされている
    assert.is_nil(Commands.custom_commands["mycmd"])
    assert.is_not_nil(Commands.custom_commands["other"])
  end)

  it("a builtin command never triggers the scan", function()
    Commands.register({ name = "save", handler = function() return true end, description = "save" })

    Commands.execute("/save", nil)

    assert.equals(0, scan_count)
  end)
end)
