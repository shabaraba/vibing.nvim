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

  it("anchors a per-chat write to the chat's own project, not Neovim's cwd (regression)", function()
    -- A :cd (or a worktree chat) between parking a resume and firing it used to resolve to a
    -- different project's store, silently losing the pending entry.
    local chat_path = tmp_root .. "/.vibing/chat/a.md"
    vim.fn.mkdir(vim.fn.fnamemodify(chat_path, ":h"), "p")

    PendingResume.put({ chat_file_path = chat_path, retry_count = 0, recorded_at = 1 })

    -- Readable back without being told where to look, and stored under the chat's own tree.
    assert.is_not_nil(PendingResume.get(chat_path))
    assert.equals(1, vim.fn.filereadable(PendingResume.get_path_for_chat(chat_path)))
  end)

  it("removes a per-chat entry from the chat's own store", function()
    local chat_path = tmp_root .. "/.vibing/chat/b.md"
    vim.fn.mkdir(vim.fn.fnamemodify(chat_path, ":h"), "p")
    PendingResume.put({ chat_file_path = chat_path, retry_count = 0, recorded_at = 1 })

    PendingResume.remove(chat_path)

    assert.is_nil(PendingResume.get(chat_path))
  end)

  it("clears every entry", function()
    PendingResume.put({ chat_file_path = "/a.md", retry_count = 0, recorded_at = 1 }, tmp_root)
    PendingResume.put({ chat_file_path = "/b.md", retry_count = 0, recorded_at = 1 }, tmp_root)

    PendingResume.clear(tmp_root)

    assert.same({}, PendingResume.load(tmp_root))
  end)
end)
