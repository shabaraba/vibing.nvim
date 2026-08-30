describe("active_stream_registry", function()
  --- Reload the module for each test so streams from one test don't leak into the next
  --- (the registry is process-global module state).
  ---@return table
  local function fresh_registry()
    package.loaded["vibing.infrastructure.adapter.modules.active_stream_registry"] = nil
    return require("vibing.infrastructure.adapter.modules.active_stream_registry")
  end

  it("returns the registered stream by handle_id", function()
    local registry = fresh_registry()
    registry.register({ handle_id = "a", adapter = {}, on_insert_choices = function() end })

    local stream = registry.get("a")
    assert.is_not_nil(stream)
    assert.equals("a", stream.handle_id)
  end)

  it("does not cross-wire two concurrently registered streams (regression)", function()
    local registry = fresh_registry()
    local a_calls, b_calls = 0, 0
    registry.register({
      handle_id = "chat-a",
      adapter = {},
      on_insert_choices = function()
        a_calls = a_calls + 1
      end,
    })
    registry.register({
      handle_id = "chat-b",
      adapter = {},
      on_insert_choices = function()
        b_calls = b_calls + 1
      end,
    })

    -- A PreToolUse hook for chat-a's process must resolve to chat-a's callbacks, never chat-b's,
    -- even though chat-b registered more recently.
    local stream_a = registry.get("chat-a")
    assert.is_not_nil(stream_a)
    stream_a.on_insert_choices({})
    assert.equals(1, a_calls)
    assert.equals(0, b_calls)

    local stream_b = registry.get("chat-b")
    assert.is_not_nil(stream_b)
    stream_b.on_insert_choices({})
    assert.equals(1, a_calls)
    assert.equals(1, b_calls)
  end)

  it("returns nil for an unknown handle_id", function()
    local registry = fresh_registry()
    registry.register({ handle_id = "a", adapter = {} })

    assert.is_nil(registry.get("unknown"))
  end)

  it("unregister only removes the matching handle_id", function()
    local registry = fresh_registry()
    registry.register({ handle_id = "a", adapter = {} })
    registry.register({ handle_id = "b", adapter = {} })

    registry.unregister("a")

    assert.is_nil(registry.get("a"))
    assert.is_not_nil(registry.get("b"))
  end)

  describe("nil handle_id fallback (back-compat)", function()
    it("returns the sole stream when exactly one is registered", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "only", adapter = {} })

      local stream = registry.get(nil)
      assert.is_not_nil(stream)
      assert.equals("only", stream.handle_id)
    end)

    it("returns nil when multiple streams are registered (avoids guessing)", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", adapter = {} })
      registry.register({ handle_id = "b", adapter = {} })

      assert.is_nil(registry.get(nil))
    end)

    it("returns nil when no streams are registered", function()
      local registry = fresh_registry()
      assert.is_nil(registry.get(nil))
    end)
  end)

  describe("get_by_chat_bufnr", function()
    it("returns the entry whose chat_bufnr matches, even with several concurrent streams", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", chat_bufnr = 11, adapter = {} })
      registry.register({ handle_id = "b", chat_bufnr = 12, adapter = {} })

      local stream = registry.get_by_chat_bufnr(12)
      assert.is_not_nil(stream)
      assert.equals("b", stream.handle_id)
    end)

    it("falls back to the sole stream when chat_bufnr is nil", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "only", chat_bufnr = 7, adapter = {} })

      local stream = registry.get_by_chat_bufnr(nil)
      assert.is_not_nil(stream)
      assert.equals("only", stream.handle_id)
    end)

    it("falls back to the sole stream when chat_bufnr doesn't match any entry", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "only", chat_bufnr = 7, adapter = {} })

      local stream = registry.get_by_chat_bufnr(99)
      assert.is_not_nil(stream)
      assert.equals("only", stream.handle_id)
    end)

    it("returns nil on mismatch when multiple streams are registered (avoids guessing)", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", chat_bufnr = 11, adapter = {} })
      registry.register({ handle_id = "b", chat_bufnr = 12, adapter = {} })

      assert.is_nil(registry.get_by_chat_bufnr(99))
    end)
  end)

  describe("find_other_active_for_session", function()
    -- A subagent chat shares its parent's session_id permanently, so two buffers can end up
    -- resuming one session; two CLI processes appending to that transcript would corrupt it.
    it("finds another buffer already streaming the same session", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", chat_bufnr = 11, session_id = "s-1", adapter = {} })

      local conflict = registry.find_other_active_for_session("s-1", 12)
      assert.is_not_nil(conflict)
      assert.equals(11, conflict.chat_bufnr)
    end)

    it("does not report a buffer's own stream as a conflict", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", chat_bufnr = 11, session_id = "s-1", adapter = {} })

      assert.is_nil(registry.find_other_active_for_session("s-1", 11))
    end)

    it("ignores streams on other sessions", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", chat_bufnr = 11, session_id = "s-1", adapter = {} })

      assert.is_nil(registry.find_other_active_for_session("s-2", 12))
    end)

    it("reports nothing once that stream has finished", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", chat_bufnr = 11, session_id = "s-1", adapter = {} })
      registry.unregister("a")

      assert.is_nil(registry.find_other_active_for_session("s-1", 12))
    end)

    it("treats a chat with no session yet as unconflicted", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", chat_bufnr = 11, session_id = "s-1", adapter = {} })

      assert.is_nil(registry.find_other_active_for_session(nil, 12))
      assert.is_nil(registry.find_other_active_for_session("", 12))
    end)
  end)

  describe("find_other_active_for_worktree", function()
    it("finds another stream running in the same worktree", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", chat_bufnr = 11, worktree_root = "/repo", adapter = {} })

      local overlap = registry.find_other_active_for_worktree("/repo", "b")
      assert.is_not_nil(overlap)
      assert.equals("a", overlap.handle_id)
    end)

    it("does not report a stream as overlapping with itself", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", chat_bufnr = 11, worktree_root = "/repo", adapter = {} })

      assert.is_nil(registry.find_other_active_for_worktree("/repo", "a"))
    end)

    it("separates two streams that register no chat_bufnr at all", function()
      -- codex/grok は chat_bufnr を登録しない。bufnr で除外すると nil == nil で
      -- 「自分自身」と誤判定され、並行実行を1つも検出できなくなる
      local registry = fresh_registry()
      registry.register({ handle_id = "a", worktree_root = "/repo", adapter = {} })

      local overlap = registry.find_other_active_for_worktree("/repo", "b")
      assert.is_not_nil(overlap)
      assert.equals("a", overlap.handle_id)
    end)

    it("ignores streams in a different worktree", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", worktree_root = "/repo", adapter = {} })

      assert.is_nil(registry.find_other_active_for_worktree("/repo/.vibing/worktrees/side", "b"))
    end)

    it("reports nothing once that stream has finished", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", worktree_root = "/repo", adapter = {} })
      registry.unregister("a")

      assert.is_nil(registry.find_other_active_for_worktree("/repo", "b"))
    end)

    it("treats a chat outside any git repository as unoverlapped", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", worktree_root = "/repo", adapter = {} })

      assert.is_nil(registry.find_other_active_for_worktree(nil, "b"))
      assert.is_nil(registry.find_other_active_for_worktree("", "b"))
    end)
  end)
end)
