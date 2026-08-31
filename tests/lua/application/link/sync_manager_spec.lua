local SyncManager = require("vibing.application.link.sync_manager")

---3メソッドだけのスキャナーを組み立てる。実ファイルを触らないので、`sync_links` 自身の
---走査・集計・エラー処理だけを見られる
---@param files string[]
---@param matches table<string, boolean>
---@param failures table<string, string>?
---@return table
local function fake_scanner(files, matches, failures)
  return {
    updated = {},
    find_target_files = function()
      return files
    end,
    contains_link = function(_, file)
      return matches[file] == true
    end,
    update_link = function(self, file, _, new_path)
      if failures and failures[file] then
        return false, failures[file]
      end
      table.insert(self.updated, { file = file, new_path = new_path })
      return true, nil
    end,
  }
end

describe("SyncManager.sync_links", function()
  it("updates only the files that contain the link", function()
    local scanner = fake_scanner({ "a.md", "b.md", "c.md" }, { ["b.md"] = true })

    local result = SyncManager.sync_links("/old.md", "/new.md", { scanner }, "/base/")

    assert.equals(1, result.updated)
    assert.equals(0, result.failed)
    assert.same({ { file = "b.md", new_path = "/new.md" } }, scanner.updated)
  end)

  it("reports total as the number of files scanned, not matched", function()
    -- 「N件更新しました」の分母ではないので、ユーザー向けの文言に使ってはいけない
    local scanner = fake_scanner({ "a.md", "b.md", "c.md" }, { ["a.md"] = true })

    local result = SyncManager.sync_links("/old.md", "/new.md", { scanner }, "/base/")

    assert.equals(3, result.total)
    assert.equals(1, result.updated)
  end)

  it("counts a failed update without aborting the rest of the sweep", function()
    local scanner = fake_scanner({ "a.md", "b.md" }, { ["a.md"] = true, ["b.md"] = true }, { ["a.md"] = "boom" })

    local result = SyncManager.sync_links("/old.md", "/new.md", { scanner }, "/base/")

    assert.equals(1, result.updated)
    assert.equals(1, result.failed)
    assert.same({ { file = "b.md", new_path = "/new.md" } }, scanner.updated)
  end)

  it("runs every scanner it is given over the same base directory", function()
    local first = fake_scanner({ "a.md" }, { ["a.md"] = true })
    local second = fake_scanner({ "b.md" }, { ["b.md"] = true })

    local result = SyncManager.sync_links("/old.md", "/new.md", { first, second }, "/base/")

    assert.equals(2, result.updated)
    assert.equals(2, result.total)
  end)

  it("counts a file twice when two scanners both match it", function()
    -- forked と orchestration の両方のリンクを持つチャットは2回数えられる。ユーザーに出る
    -- 「Updated N linked file(s)」がファイル数ではなくリンク数であることの根拠
    local first = fake_scanner({ "a.md" }, { ["a.md"] = true })
    local second = fake_scanner({ "a.md" }, { ["a.md"] = true })

    local result = SyncManager.sync_links("/old.md", "/new.md", { first, second }, "/base/")

    assert.equals(2, result.updated)
  end)

  it("returns zeros when no scanner finds anything", function()
    local result = SyncManager.sync_links("/old.md", "/new.md", { fake_scanner({}, {}) }, "/base/")

    assert.same({ total = 0, updated = 0, failed = 0 }, result)
  end)
end)
