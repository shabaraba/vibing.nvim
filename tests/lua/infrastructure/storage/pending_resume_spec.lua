describe("pending_resume", function()
  local PendingResume = require("vibing.infrastructure.storage.pending_resume")

  local tmp_root

  before_each(function()
    tmp_root = vim.fn.tempname()
    vim.fn.mkdir(tmp_root, "p")
  end)

  after_each(function()
    if tmp_root then
      vim.fn.delete(tmp_root, "rf")
    end
  end)

  it("returns an empty table when no store exists", function()
    assert.same({}, PendingResume.load(tmp_root))
  end)

  it("round-trips an entry", function()
    PendingResume.put({
      chat_file_path = "/proj/.vibing/chat/a.md",
      resets_at = 1778193600,
      limit_type = "five_hour",
      retry_count = 0,
      recorded_at = 1778180000,
    }, tmp_root)

    local entry = PendingResume.get("/proj/.vibing/chat/a.md", tmp_root)
    assert.is_not_nil(entry)
    assert.equals(1778193600, entry.resets_at)
    assert.equals("five_hour", entry.limit_type)
    assert.equals(0, entry.retry_count)
  end)

  it("keeps entries for other chats when one is removed", function()
    PendingResume.put({ chat_file_path = "/a.md", retry_count = 0, recorded_at = 1 }, tmp_root)
    PendingResume.put({ chat_file_path = "/b.md", retry_count = 0, recorded_at = 1 }, tmp_root)

    PendingResume.remove("/a.md", tmp_root)

    assert.is_nil(PendingResume.get("/a.md", tmp_root))
    assert.is_not_nil(PendingResume.get("/b.md", tmp_root))
  end)

  it("stays a keyed object after the last entry is removed (regression)", function()
    -- An empty Lua table encodes as "[]", which would decode back as a list and break every
    -- keyed lookup on the next load.
    PendingResume.put({ chat_file_path = "/only.md", retry_count = 0, recorded_at = 1 }, tmp_root)
    PendingResume.remove("/only.md", tmp_root)

    assert.same({}, PendingResume.load(tmp_root))
    PendingResume.put({ chat_file_path = "/again.md", retry_count = 0, recorded_at = 1 }, tmp_root)
    assert.is_not_nil(PendingResume.get("/again.md", tmp_root))
  end)

  it("ignores a corrupt store instead of erroring", function()
    local path = PendingResume.get_path(tmp_root)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "{ this is not json" }, path)

    assert.same({}, PendingResume.load(tmp_root))
  end)

  it("clears every entry", function()
    PendingResume.put({ chat_file_path = "/a.md", retry_count = 0, recorded_at = 1 }, tmp_root)
    PendingResume.put({ chat_file_path = "/b.md", retry_count = 0, recorded_at = 1 }, tmp_root)

    PendingResume.clear(tmp_root)

    assert.same({}, PendingResume.load(tmp_root))
  end)
end)
