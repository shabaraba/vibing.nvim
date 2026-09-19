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

  -- The guess belongs to the caller that asks for it by name, never to the accessor: an accessor
  -- that falls back is how `get_active_opts` used to answer a late hook with another chat's
  -- decisions. `get_by_chat_bufnr` is the one lookup that still wants it.
  describe("no guess is baked into get()", function()
    it("returns nil for a nil turn id even when exactly one stream is registered", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "only", adapter = {} })

      assert.is_nil(registry.get(nil))
      assert.is_not_nil(registry.sole_active())
    end)
  end)

  -- The inbound path for both shell hooks. `VIBING_PROCESS_ID` is fixed when the child is spawned,
  -- so a process is the only thing a hook can name; `rpc/hook_scope.lua` turns that into a turn
  -- through here. Every entry below carries a turn id and a process id that are **different
  -- values**, because with one value the lookup works whichever field it reads.
  describe("find_by_process_id", function()
    local function register_chat(registry, name)
      registry.register({ handle_id = name .. "-turn", process_id = name .. "-process", adapter = {} })
    end

    it("resolves the process to the turn it has open", function()
      local registry = fresh_registry()
      register_chat(registry, "a")
      register_chat(registry, "b")

      assert.equals("b-turn", registry.find_by_process_id("b-process").handle_id)
      assert.equals("a-turn", registry.find_by_process_id("a-process").handle_id)
    end)

    it("does not answer to a turn id", function()
      -- The two key spaces are separate. Answering here would make every consumer's choice of id
      -- arbitrary, which is the state this split exists to leave.
      local registry = fresh_registry()
      register_chat(registry, "a")

      assert.is_nil(registry.find_by_process_id("a-turn"))
    end)

    it("refuses to guess for a process it does not know, even with one stream live", function()
      -- Deliberately stricter than `get(nil)`. An id that is present but matches nothing is a
      -- straggler from a turn that already ended; lending it the live chat's answer is the #667
      -- class of defect. Whether to fall back is the caller's decision, in hook_scope.
      local registry = fresh_registry()
      register_chat(registry, "a")

      assert.is_nil(registry.find_by_process_id("a-process-that-died"))
      assert.is_nil(registry.find_by_process_id(nil))
    end)

    it("stops answering once the stream unregisters", function()
      local registry = fresh_registry()
      register_chat(registry, "a")
      registry.unregister("a-turn")

      assert.is_nil(registry.find_by_process_id("a-process"))
    end)
  end)

  describe("sole_active", function()
    it("is the one stream in flight, or nil when that is ambiguous", function()
      local registry = fresh_registry()
      assert.is_nil(registry.sole_active())

      registry.register({ handle_id = "only-turn", process_id = "only-process", adapter = {} })
      assert.equals("only-turn", registry.sole_active().handle_id)

      registry.register({ handle_id = "second-turn", process_id = "second-process", adapter = {} })
      assert.is_nil(registry.sole_active())
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
      -- grok など chat_bufnr を登録しないbackendもある。bufnr で除外すると nil == nil で
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

  describe("subagent count (#701)", function()
    it("starts a newly registered stream at zero", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", adapter = {} })

      assert.equals(0, registry.total_subagent_count())
    end)

    it("sums subagents across every active stream", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", adapter = {} })
      registry.register({ handle_id = "b", adapter = {} })

      registry.increment_subagent_count("a")
      registry.increment_subagent_count("a")
      registry.increment_subagent_count("b")

      assert.equals(3, registry.total_subagent_count())
    end)

    it("decrements only the named stream's count", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", adapter = {} })
      registry.increment_subagent_count("a")
      registry.increment_subagent_count("a")

      registry.decrement_subagent_count("a")

      assert.equals(1, registry.total_subagent_count())
    end)

    it("never goes negative on an unmatched decrement", function()
      local registry = fresh_registry()
      registry.register({ handle_id = "a", adapter = {} })

      registry.decrement_subagent_count("a")
      registry.decrement_subagent_count("a")

      assert.equals(0, registry.total_subagent_count())
    end)

    it("ignores an unknown or nil handle_id rather than erroring", function()
      local registry = fresh_registry()

      registry.increment_subagent_count("unknown")
      registry.increment_subagent_count(nil)
      registry.decrement_subagent_count("unknown")
      registry.decrement_subagent_count(nil)

      assert.equals(0, registry.total_subagent_count())
    end)

    it("drops a stream's count entirely once it is unregistered", function()
      -- A turn that dies with a subagent still running must not leak that count forever —
      -- there is no SubagentStop-equivalent event to decrement it on that path.
      local registry = fresh_registry()
      registry.register({ handle_id = "a", adapter = {} })
      registry.increment_subagent_count("a")

      registry.unregister("a")

      assert.equals(0, registry.total_subagent_count())
    end)
  end)
end)
