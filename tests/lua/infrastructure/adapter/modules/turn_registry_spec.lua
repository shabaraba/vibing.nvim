describe("turn_registry", function()
  local ProcessRegistry, TurnRegistry

  --- Reload both modules for each test so turns from one test don't leak into the next
  --- (both registries are process-global module state).
  local function fresh_registries()
    package.loaded["vibing.infrastructure.adapter.modules.process_registry"] = nil
    package.loaded["vibing.infrastructure.adapter.modules.turn_registry"] = nil
    ProcessRegistry = require("vibing.infrastructure.adapter.modules.process_registry")
    TurnRegistry = require("vibing.infrastructure.adapter.modules.turn_registry")
  end

  --- Register a process and open a turn on it, the way `cli_adapter.stream()` does. The turn id and
  --- the process id are **different values** throughout, because with one value every lookup works
  --- whichever field it happens to read.
  ---@param name string
  ---@param fields table|nil extra fields for the turn entry
  ---@return table process, table turn
  local function start(name, fields)
    local process = {
      process_id = name .. "-process",
      chat_bufnr = fields and fields.chat_bufnr or nil,
      session_id = fields and fields.session_id or nil,
      adapter = {},
    }
    ProcessRegistry.register(process)
    local turn = {
      turn_id = name .. "-turn",
      process = process,
      worktree_root = fields and fields.worktree_root or nil,
      on_insert_choices = fields and fields.on_insert_choices or nil,
    }
    TurnRegistry.open(turn)
    return process, turn
  end

  before_each(fresh_registries)

  describe("open and close", function()
    it("is the only writer of the process entry's active_turn_id", function()
      local process = start("a")
      assert.equals("a-turn", process.active_turn_id)

      TurnRegistry.close("a-turn")
      assert.is_nil(process.active_turn_id)
    end)

    it("leaves the process registered when its turn closes", function()
      -- A process outlives its turn under a resident transport (#774); whether it also goes is the
      -- adapter's call, not this module's.
      start("a")
      TurnRegistry.close("a-turn")

      assert.is_not_nil(ProcessRegistry.get("a-process"))
      assert.is_nil(TurnRegistry.get("a-turn"))
    end)

    it("does not clear the link when a turn that is no longer the open one closes", function()
      -- The resident-transport shape: turn N's `on_done` can land after turn N+1 has already
      -- started on the same process. Clearing unconditionally would null the *live* turn's link,
      -- and every hook naming that process would resolve to nil from then on.
      local process = start("a")
      TurnRegistry.open({ turn_id = "a-turn-2", process = process })

      TurnRegistry.close("a-turn")

      assert.equals("a-turn-2", process.active_turn_id)
      assert.is_not_nil(TurnRegistry.get("a-turn-2"))
    end)

    it("is a no-op when that turn has already closed", function()
      local process = start("a")
      TurnRegistry.close("a-turn")
      TurnRegistry.close("a-turn")

      assert.is_nil(process.active_turn_id)
    end)

    it("does not cross-wire two concurrently open turns (regression)", function()
      local a_calls, b_calls = 0, 0
      start("a", {
        on_insert_choices = function()
          a_calls = a_calls + 1
        end,
      })
      start("b", {
        on_insert_choices = function()
          b_calls = b_calls + 1
        end,
      })

      -- A PreToolUse hook for chat-a's process must resolve to chat-a's callbacks, never chat-b's,
      -- even though chat-b opened more recently.
      TurnRegistry.of_process("a-process").on_insert_choices({})
      assert.equals(1, a_calls)
      assert.equals(0, b_calls)

      TurnRegistry.of_process("b-process").on_insert_choices({})
      assert.equals(1, a_calls)
      assert.equals(1, b_calls)
    end)
  end)

  describe("get", function()
    it("returns the turn with that id", function()
      start("a")
      assert.equals("a-turn", TurnRegistry.get("a-turn").turn_id)
    end)

    it("never falls back, not for an unknown id and not for nil", function()
      -- `git_snapshot`'s TTL sweep asks this about every baseline it holds. A sole-open fallback
      -- would report every stale baseline as still open whenever one turn happened to be running,
      -- stopping the sweep and leaving `refs/worktree/vibing/` to grow without bound.
      start("a")

      assert.is_nil(TurnRegistry.get("a-turn-that-ended"))
      assert.is_nil(TurnRegistry.get(nil))
    end)

    it("does not answer to a process id", function()
      -- The two key spaces are separate. Answering here would make every consumer's choice of id
      -- arbitrary, which is the state this split exists to leave.
      start("a")
      assert.is_nil(TurnRegistry.get("a-process"))
    end)
  end)

  describe("of_process", function()
    it("resolves the process to the turn it has open", function()
      start("a")
      start("b")

      assert.equals("b-turn", TurnRegistry.of_process("b-process").turn_id)
      assert.equals("a-turn", TurnRegistry.of_process("a-process").turn_id)
    end)

    it("returns nil for a process that is idle between turns", function()
      start("a")
      TurnRegistry.close("a-turn")

      assert.is_nil(TurnRegistry.of_process("a-process"))
    end)

    it("refuses to guess for a process it does not know, even with one turn open", function()
      start("a")

      assert.is_nil(TurnRegistry.of_process("a-process-that-died"))
      assert.is_nil(TurnRegistry.of_process(nil))
    end)
  end)

  describe("sole_open", function()
    it("is the one turn open, or nil when that is ambiguous", function()
      assert.is_nil(TurnRegistry.sole_open())

      start("a")
      assert.equals("a-turn", TurnRegistry.sole_open().turn_id)

      start("b")
      assert.is_nil(TurnRegistry.sole_open())
    end)
  end)

  describe("get_by_chat_bufnr", function()
    it("returns the turn open in that chat, even with several concurrent turns", function()
      start("a", { chat_bufnr = 11 })
      start("b", { chat_bufnr = 12 })

      assert.equals("b-turn", TurnRegistry.get_by_chat_bufnr(12).turn_id)
    end)

    it("falls back to the sole open turn when chat_bufnr is nil", function()
      start("a", { chat_bufnr = 7 })

      assert.equals("a-turn", TurnRegistry.get_by_chat_bufnr(nil).turn_id)
    end)

    it("falls back to the sole open turn when no process serves that bufnr", function()
      -- `--resume` replays earlier turns, so the model can read a buffer number from a previous
      -- Neovim session and pass one that no longer exists.
      start("a", { chat_bufnr = 7 })

      assert.equals("a-turn", TurnRegistry.get_by_chat_bufnr(99).turn_id)
    end)

    it("returns nil on mismatch when several turns are open (avoids guessing)", function()
      start("a", { chat_bufnr = 11 })
      start("b", { chat_bufnr = 12 })

      assert.is_nil(TurnRegistry.get_by_chat_bufnr(99))
    end)

    it("returns nil for a chat whose process is idle, rather than another chat's turn", function()
      -- The bufnr resolved: that chat simply has nothing open. Answering with some other chat's
      -- turn would route its question into the wrong buffer — the #667 shape.
      start("a", { chat_bufnr = 11 })
      start("b", { chat_bufnr = 12 })
      TurnRegistry.close("b-turn")

      assert.is_nil(TurnRegistry.get_by_chat_bufnr(12))
    end)
  end)

  describe("find_other_writing_in", function()
    it("finds another turn running in the same worktree", function()
      start("a", { chat_bufnr = 11, worktree_root = "/repo" })

      local overlap = TurnRegistry.find_other_writing_in("/repo", "b-turn")
      assert.is_not_nil(overlap)
      assert.equals("a-turn", overlap.turn_id)
    end)

    it("does not report a turn as overlapping with itself", function()
      start("a", { chat_bufnr = 11, worktree_root = "/repo" })

      assert.is_nil(TurnRegistry.find_other_writing_in("/repo", "a-turn"))
    end)

    it("stops reporting an overlap once the other turn closes, with its process still alive", function()
      -- The reason this is per turn and not per process: two resident processes in one repository
      -- would otherwise make every chat overlap every other one forever, and the #625 snapshot
      -- mechanism would never be used again.
      start("a", { chat_bufnr = 11, worktree_root = "/repo" })
      TurnRegistry.close("a-turn")

      assert.is_not_nil(ProcessRegistry.get("a-process"))
      assert.is_nil(TurnRegistry.find_other_writing_in("/repo", "b-turn"))
    end)

    it("separates two turns that register no chat_bufnr at all", function()
      -- grok など chat_bufnr を登録しないbackendもある。bufnr で除外すると nil == nil で
      -- 「自分自身」と誤判定され、並行実行を1つも検出できなくなる
      start("a", { worktree_root = "/repo" })

      local overlap = TurnRegistry.find_other_writing_in("/repo", "b-turn")
      assert.is_not_nil(overlap)
      assert.equals("a-turn", overlap.turn_id)
    end)

    it("ignores turns in a different worktree", function()
      start("a", { worktree_root = "/repo" })

      assert.is_nil(TurnRegistry.find_other_writing_in("/repo/.vibing/worktrees/side", "b-turn"))
    end)

    it("treats a chat outside any git repository as unoverlapped", function()
      start("a", { worktree_root = "/repo" })

      assert.is_nil(TurnRegistry.find_other_writing_in(nil, "b-turn"))
      assert.is_nil(TurnRegistry.find_other_writing_in("", "b-turn"))
    end)
  end)

  describe("subagent count (#701)", function()
    it("starts a newly opened turn at zero", function()
      start("a")

      assert.equals(0, TurnRegistry.total_subagent_count())
    end)

    it("sums subagents across every open turn", function()
      start("a")
      start("b")

      TurnRegistry.increment_subagent_count("a-turn")
      TurnRegistry.increment_subagent_count("a-turn")
      TurnRegistry.increment_subagent_count("b-turn")

      assert.equals(3, TurnRegistry.total_subagent_count())
    end)

    it("decrements only the named turn's count", function()
      start("a")
      TurnRegistry.increment_subagent_count("a-turn")
      TurnRegistry.increment_subagent_count("a-turn")

      TurnRegistry.decrement_subagent_count("a-turn")

      assert.equals(1, TurnRegistry.total_subagent_count())
    end)

    it("never goes negative on an unmatched decrement", function()
      start("a")

      TurnRegistry.decrement_subagent_count("a-turn")
      TurnRegistry.decrement_subagent_count("a-turn")

      assert.equals(0, TurnRegistry.total_subagent_count())
    end)

    it("ignores an unknown or nil turn_id rather than erroring", function()
      TurnRegistry.increment_subagent_count("unknown")
      TurnRegistry.increment_subagent_count(nil)
      TurnRegistry.decrement_subagent_count("unknown")
      TurnRegistry.decrement_subagent_count(nil)

      assert.equals(0, TurnRegistry.total_subagent_count())
    end)

    it("drops a turn's count entirely once it closes", function()
      -- A turn that dies with a subagent still running must not leak that count forever —
      -- there is no SubagentStop-equivalent event to decrement it on that path.
      start("a")
      TurnRegistry.increment_subagent_count("a-turn")

      TurnRegistry.close("a-turn")

      assert.equals(0, TurnRegistry.total_subagent_count())
    end)
  end)
end)
