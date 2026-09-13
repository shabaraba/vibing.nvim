-- diff_opener.lua は `gd` の入口。ここで固定したいのは行き先の分岐だけ。
-- そのターンのpatchがあればpatch_viewer、無ければHEADとの差分、どちらも無理なら何も開かない。
local DiffOpener = require("vibing.presentation.chat.modules.diff_opener")

describe("diff_opener.open", function()
  local saved = {}
  local calls

  local function stub(name, module)
    saved[name] = saved[name] or { value = package.loaded[name], had = package.loaded[name] ~= nil }
    package.loaded[name] = module
  end

  before_each(function()
    calls = { patch_viewer = {}, head_diff = {}, notified = {} }

    stub("vibing.ui.patch_viewer", {
      show = function(session_id, patch_filename, file_path)
        table.insert(calls.patch_viewer, { session_id, patch_filename, file_path })
      end,
    })
    stub("vibing.core.utils.diff_selector", {
      show_diff = function(file_path, session_id, cwd)
        table.insert(calls.head_diff, { file_path, session_id, cwd })
      end,
    })
    stub("vibing.core.utils.notify", {
      info = function(message)
        table.insert(calls.notified, message)
      end,
    })
    stub("vibing.presentation.chat.view", {
      get_chat_buffer = function()
        return nil
      end,
    })
  end)

  after_each(function()
    for name, entry in pairs(saved) do
      package.loaded[name] = entry.had and entry.value or nil
    end
    saved = {}
  end)

  local function with_cursor(session_id, patch_filename, file_path)
    stub("vibing.presentation.chat.modules.patch_finder", {
      get_session_id = function()
        return session_id
      end,
      find_nearest_patch = function()
        return patch_filename
      end,
    })
    stub("vibing.core.utils.file_path", {
      is_cursor_on_file_path = function()
        return file_path
      end,
    })
  end

  it("opens the patch viewer when the turn has a patch", function()
    with_cursor("sess-1", "/tmp/turn.patch", "lua/a.lua")

    DiffOpener.open(1)

    assert.same({ { "sess-1", "/tmp/turn.patch", "lua/a.lua" } }, calls.patch_viewer)
    assert.same({}, calls.head_diff)
  end)

  it("opens the patch viewer even with no path under the cursor", function()
    -- 1行サマリの節ではカーソル下に個別のパスが無い。一覧から選べるので、それでも開く
    with_cursor("sess-1", "/tmp/turn.patch", nil)

    DiffOpener.open(1)

    assert.same({ { "sess-1", "/tmp/turn.patch", nil } }, calls.patch_viewer)
  end)

  it("falls back to the diff against HEAD, saying why, when the turn has no patch", function()
    with_cursor("sess-1", nil, "lua/a.lua")

    DiffOpener.open(1)

    assert.same({}, calls.patch_viewer)
    assert.same({ { "lua/a.lua", "sess-1", nil } }, calls.head_diff)
    -- 見た目が同じで意味が違うので、黙って差し替えてはいけない
    assert.equals(1, #calls.notified)
    assert.is_truthy(calls.notified[1]:match("HEAD"))
  end)

  it("opens nothing when there is neither a patch nor a path under the cursor", function()
    with_cursor(nil, nil, nil)

    DiffOpener.open(1)

    assert.same({}, calls.patch_viewer)
    assert.same({}, calls.head_diff)
    assert.same({}, calls.notified)
  end)
end)
