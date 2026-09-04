describe("turn_state", function()
  local TurnState = require("vibing.infrastructure.storage.turn_state")

  local dir, chat, now

  before_each(function()
    TurnState.clear_cache()
    now = os.time()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    chat = dir .. "/chat.md"
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
    TurnState.clear_cache()
  end)

  it("reads back what it recorded", function()
    TurnState.record(chat, { at = now, model = "claude-opus-5", version = "2.1.231", compacted = true })

    local loaded = TurnState.load(chat)
    assert.equals(now, loaded.at)
    assert.equals("claude-opus-5", loaded.model)
    assert.equals("2.1.231", loaded.version)
    assert.is_true(loaded.compacted)
  end)

  it("keeps each chat's record apart", function()
    local other = dir .. "/other.md"
    TurnState.record(chat, { at = now, model = "a" })
    TurnState.record(other, { at = now, model = "b" })

    assert.equals("a", TurnState.load(chat).model)
    assert.equals("b", TurnState.load(other).model)
  end)

  it("replaces a chat's record rather than accumulating turns", function()
    TurnState.record(chat, { at = now - 100, model = "a" })
    TurnState.record(chat, { at = now, model = "b" })

    assert.equals("b", TurnState.load(chat).model)
  end)

  it("has nothing to say about a chat it has never seen", function()
    assert.is_nil(TurnState.load(chat))
    assert.is_nil(TurnState.load(nil))
    assert.is_nil(TurnState.load(""))
  end)

  it("finds the record whichever spelling of the path it is handed", function()
    -- `nvim_buf_get_name` returns a path the editor already resolved, while a caller holding the
    -- string it opened the chat with has not. On macOS a temp path is `/var/...` on one side and
    -- `/private/var/...` on the other -- two keys and two store files for one chat.
    local resolved = vim.fn.resolve(vim.fn.fnamemodify(chat, ":p"))
    TurnState.record(chat, { at = now, model = "a" })

    assert.equals("a", TurnState.load(resolved).model)
  end)

  it("drops entries older than the retention window on the next write", function()
    local stale = dir .. "/stale.md"
    TurnState.record(stale, { at = now - 40 * 24 * 60 * 60 })
    TurnState.record(chat, { at = now })

    -- A chat untouched for a month says nothing useful about a cache TTL measured in hours, and
    -- this sweep is what bounds the file.
    assert.is_nil(TurnState.load(stale))
    assert.truthy(TurnState.load(chat))
  end)

  it("keeps the record it is writing, however old its timestamp", function()
    -- The sweep runs before the insert. Running it after would let the retention rule apply to
    -- the entry being stored, so a clock that jumped backwards would silently store nothing.
    TurnState.record(chat, { at = now - 90 * 24 * 60 * 60, model = "a" })

    assert.equals("a", TurnState.load(chat).model)
  end)

  it("treats an unreadable store as empty instead of erroring", function()
    vim.fn.mkdir(dir .. "/.vibing", "p")
    vim.fn.writefile({ "{ not json" }, TurnState.get_path(chat))

    assert.is_nil(TurnState.load(chat))
    -- And a write over it still succeeds, so one corrupt file costs a single turn's diagnosis
    -- rather than every turn after it.
    assert.is_true(TurnState.record(chat, { at = now, model = "a" }))
    assert.equals("a", TurnState.load(chat).model)
  end)

  it("ignores a record with no timestamp to compare against", function()
    vim.fn.mkdir(dir .. "/.vibing", "p")
    local key = vim.fn.resolve(vim.fn.fnamemodify(chat, ":p"))
    vim.fn.writefile({ vim.json.encode({ [key] = { model = "a" } }) }, TurnState.get_path(chat))

    assert.is_nil(TurnState.load(chat))
  end)

  it("refuses a call with nothing to key on", function()
    assert.is_false(TurnState.record(nil, { at = now }))
    assert.is_false(TurnState.record(chat, nil))
  end)

  it("stores beside the chat file, under .vibing/", function()
    local resolved_dir = vim.fn.resolve(vim.fn.fnamemodify(chat, ":p:h"))

    assert.equals(resolved_dir .. "/.vibing/turn-state.json", TurnState.get_path(chat))
  end)
end)
