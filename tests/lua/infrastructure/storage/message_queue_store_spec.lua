describe("message_queue_store", function()
  local Store = require("vibing.infrastructure.storage.message_queue_store")

  local tmp_root

  before_each(function()
    tmp_root = vim.fn.tempname()
    vim.fn.mkdir(tmp_root, "p")
    Store.clear_cache()
  end)

  after_each(function()
    if tmp_root then
      vim.fn.delete(tmp_root, "rf")
    end
    Store.clear_cache()
  end)

  it("returns an empty table when no store exists", function()
    assert.same({}, Store.load(tmp_root))
  end)

  it("round-trips a destination's queue", function()
    Store.put("/proj/.vibing/chat/b.md", {
      { body = "hello", from_file_path = "/proj/.vibing/chat/a.md" },
    }, tmp_root)

    local entries = Store.load(tmp_root)
    assert.is_not_nil(entries["/proj/.vibing/chat/b.md"])
    assert.equals(1, #entries["/proj/.vibing/chat/b.md"])
    assert.equals("hello", entries["/proj/.vibing/chat/b.md"][1].body)
  end)

  it("keeps entries for other destinations when one is cleared", function()
    Store.put("/a.md", { { body = "for a" } }, tmp_root)
    Store.put("/b.md", { { body = "for b" } }, tmp_root)

    Store.put("/a.md", nil, tmp_root)

    local entries = Store.load(tmp_root)
    assert.is_nil(entries["/a.md"])
    assert.is_not_nil(entries["/b.md"])
  end)

  it("stays a keyed object after the last entry is removed (regression)", function()
    -- An empty Lua table encodes as "[]", which would decode back as a list and break every
    -- keyed lookup on the next load — the same regression pending_resume.lua guards against.
    Store.put("/only.md", { { body = "x" } }, tmp_root)
    Store.put("/only.md", nil, tmp_root)

    assert.same({}, Store.load(tmp_root))
    Store.put("/again.md", { { body = "y" } }, tmp_root)
    assert.is_not_nil(Store.load(tmp_root)["/again.md"])
  end)

  it("ignores a corrupt store instead of erroring", function()
    local path = Store.get_path(tmp_root)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "{ this is not json" }, path)

    assert.same({}, Store.load(tmp_root))
  end)
end)
