-- tests/lua/infrastructure/workspace/meta_spec.lua
local Meta = require("vibing.infrastructure.workspace.meta")

describe("vibing.infrastructure.workspace.meta", function()
  local meta_path

  before_each(function()
    meta_path = vim.fn.tempname() .. "-meta.yaml"
  end)

  after_each(function()
    vim.fn.delete(meta_path)
  end)

  it("writes and reads back a meta.yaml", function()
    local ok = Meta.write(meta_path, {
      workspace_id = "0001-fix-auth-session-bug",
      branch = "fix-auth-session-bug",
      created_at = "2026-07-03T10:00:00",
      description = "auth session bug fix",
      chat_files = {},
    })
    assert.is_true(ok)

    local data = Meta.read(meta_path)
    assert.equals("0001-fix-auth-session-bug", data.workspace_id)
    assert.equals("fix-auth-session-bug", data.branch)
    assert.equals("auth session bug fix", data.description)
    assert.same({}, data.chat_files)
  end)

  it("returns nil when reading a missing file", function()
    assert.is_nil(Meta.read(meta_path))
  end)

  it("adds a chat_file to an empty list", function()
    Meta.write(meta_path, { workspace_id = "x", branch = "x", chat_files = {} })
    local ok = Meta.add_chat_file(meta_path, ".vibing/chat/a.md")
    assert.is_true(ok)

    local data = Meta.read(meta_path)
    assert.same({ ".vibing/chat/a.md" }, data.chat_files)
  end)

  it("does not duplicate an existing chat_file entry", function()
    Meta.write(meta_path, { workspace_id = "x", branch = "x", chat_files = { ".vibing/chat/a.md" } })
    Meta.add_chat_file(meta_path, ".vibing/chat/a.md")

    local data = Meta.read(meta_path)
    assert.same({ ".vibing/chat/a.md" }, data.chat_files)
  end)

  it("appends a second chat_file entry", function()
    Meta.write(meta_path, { workspace_id = "x", branch = "x", chat_files = { ".vibing/chat/a.md" } })
    Meta.add_chat_file(meta_path, ".vibing/chat/b.md")

    local data = Meta.read(meta_path)
    assert.same({ ".vibing/chat/a.md", ".vibing/chat/b.md" }, data.chat_files)
  end)

  it("replaces a chat_file path", function()
    Meta.write(meta_path, { workspace_id = "x", branch = "x", chat_files = { ".vibing/chat/a.md", ".vibing/chat/b.md" } })
    local ok = Meta.replace_chat_file(meta_path, ".vibing/chat/a.md", ".vibing/chat/renamed.md")
    assert.is_true(ok)

    local data = Meta.read(meta_path)
    assert.same({ ".vibing/chat/renamed.md", ".vibing/chat/b.md" }, data.chat_files)
  end)

  it("returns false when replacing a path that is not in the list", function()
    Meta.write(meta_path, { workspace_id = "x", branch = "x", chat_files = { ".vibing/chat/a.md" } })
    local ok, err = Meta.replace_chat_file(meta_path, ".vibing/chat/missing.md", ".vibing/chat/renamed.md")
    assert.is_false(ok)
    assert.is_not_nil(err)
  end)
end)
