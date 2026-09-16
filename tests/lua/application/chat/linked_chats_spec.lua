-- frontmatter のリンク網を、向きを落として辿れることを固定する。
--
-- いちばん壊れやすいのは逆向きの辺。`forked_from` / `continued_from` / `orchestrated_by` は
-- 子から親にしか書かれないので、自分の frontmatter だけを読む実装でも「オーケストレータから
-- ワーカー」は通ってしまい、「fork 元から fork 先」だけが黙って落ちる。

local LinkedChats = require("vibing.application.chat.linked_chats")
local FileManager = require("vibing.presentation.chat.modules.file_manager")

describe("linked_chats.collect", function()
  local tmpdir
  local original_get_save_directory

  ---@param name string
  ---@param frontmatter string[]
  ---@return string abs
  local function write_chat(name, frontmatter)
    local path = tmpdir .. "/" .. name
    local lines = { "---", "vibing.nvim: true" }
    vim.list_extend(lines, frontmatter)
    vim.list_extend(lines, { "---", "", "# Vibing Chat", "" })
    vim.fn.writefile(lines, path)
    return path
  end

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    original_get_save_directory = FileManager.get_save_directory
    FileManager.get_save_directory = function()
      return tmpdir
    end
  end)

  after_each(function()
    FileManager.get_save_directory = original_get_save_directory
    vim.fn.delete(tmpdir, "rf")
  end)

  ---@param entries {path: string, abs: string, bufnr: number?}[]
  ---@return string[] ファイル名の並び
  local function names(entries)
    local out = {}
    for _, entry in ipairs(entries) do
      table.insert(out, vim.fn.fnamemodify(entry.abs, ":t"))
    end
    return out
  end

  it("walks orchestration links transitively", function()
    local origin = write_chat("origin.md", { "orchestrated:", "  - " .. tmpdir .. "/worker.md" })
    write_chat("worker.md", {
      "orchestrated_by: " .. tmpdir .. "/origin.md",
      "orchestrated:",
      "  - " .. tmpdir .. "/grandchild.md",
    })
    write_chat("grandchild.md", { "orchestrated_by: " .. tmpdir .. "/worker.md" })
    write_chat("unrelated.md", {})

    assert.same({ "worker.md", "grandchild.md" }, names(LinkedChats.collect(origin)))
  end)

  it("reaches a chat that was forked from this one", function()
    -- fork 元の frontmatter には何も書かれない。保存ディレクトリを走査して初めて見つかる
    local origin = write_chat("origin.md", {})
    write_chat("fork.md", { "forked_from: " .. tmpdir .. "/origin.md" })

    assert.same({ "fork.md" }, names(LinkedChats.collect(origin)))
  end)

  it("reaches the chat a handoff came from", function()
    local origin = write_chat("continuation.md", { "continued_from: " .. tmpdir .. "/source.md" })
    write_chat("source.md", {})

    assert.same({ "source.md" }, names(LinkedChats.collect(origin)))
  end)

  it("never returns the origin itself", function()
    local origin = write_chat("origin.md", { "orchestrated:", "  - " .. tmpdir .. "/origin.md" })

    assert.same({}, names(LinkedChats.collect(origin)))
  end)

  it("drops a link whose file is gone but keeps walking the rest", function()
    local origin = write_chat("origin.md", {
      "orchestrated:",
      "  - " .. tmpdir .. "/deleted.md",
      "  - " .. tmpdir .. "/worker.md",
    })
    write_chat("worker.md", {})

    assert.same({ "worker.md" }, names(LinkedChats.collect(origin)))
  end)

  it("stops on a cycle instead of looping", function()
    local origin = write_chat("a.md", { "orchestrated:", "  - " .. tmpdir .. "/b.md" })
    write_chat("b.md", { "orchestrated:", "  - " .. tmpdir .. "/a.md" })

    assert.same({ "b.md" }, names(LinkedChats.collect(origin)))
  end)

  it("returns nothing for a chat that was never saved", function()
    assert.same({}, LinkedChats.collect(nil))
  end)
end)
