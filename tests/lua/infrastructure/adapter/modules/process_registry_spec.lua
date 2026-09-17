describe("process_registry", function()
  --- Reload the module for each test so processes from one test don't leak into the next
  --- (the registry is process-global module state).
  ---@return table
  local function fresh_registry()
    package.loaded["vibing.infrastructure.adapter.modules.process_registry"] = nil
    package.loaded["vibing.infrastructure.adapter.modules.turn_registry"] = nil
    return require("vibing.infrastructure.adapter.modules.process_registry")
  end

  describe("get", function()
    -- The inbound path for both shell hooks. `VIBING_PROCESS_ID` is fixed when the child is
    -- spawned, so a process is the only thing a hook can name; `rpc/hook_scope.lua` turns that into
    -- a turn through here.
    it("returns the registered process", function()
      local registry = fresh_registry()
      registry.register({ process_id = "a-process", adapter = {} })
      registry.register({ process_id = "b-process", adapter = {} })

      assert.equals("a-process", registry.get("a-process").process_id)
      assert.equals("b-process", registry.get("b-process").process_id)
    end)

    it("refuses to guess for a process it does not know, even with one process live", function()
      -- An id that is present but matches nothing is a straggler from a process that already died;
      -- lending it the live chat's answer is the #667 class of defect. Whether to fall back is the
      -- caller's decision, in hook_scope.
      local registry = fresh_registry()
      registry.register({ process_id = "a-process", adapter = {} })

      assert.is_nil(registry.get("a-process-that-died"))
      assert.is_nil(registry.get(nil))
    end)

    it("stops answering once the process is unregistered", function()
      local registry = fresh_registry()
      registry.register({ process_id = "a-process", adapter = {} })
      registry.unregister("a-process")

      assert.is_nil(registry.get("a-process"))
    end)

    it("unregister only removes the matching process", function()
      local registry = fresh_registry()
      registry.register({ process_id = "a", adapter = {} })
      registry.register({ process_id = "b", adapter = {} })

      registry.unregister("a")

      assert.is_nil(registry.get("a"))
      assert.is_not_nil(registry.get("b"))
    end)
  end)

  describe("find_by_chat_bufnr", function()
    it("returns the process serving that chat, with several live", function()
      local registry = fresh_registry()
      registry.register({ process_id = "a", chat_bufnr = 11, adapter = {} })
      registry.register({ process_id = "b", chat_bufnr = 12, adapter = {} })

      assert.equals("b", registry.find_by_chat_bufnr(12).process_id)
    end)

    it("returns nil for a bufnr no process is serving, and for nil", function()
      local registry = fresh_registry()
      registry.register({ process_id = "a", chat_bufnr = 11, adapter = {} })

      assert.is_nil(registry.find_by_chat_bufnr(99))
      assert.is_nil(registry.find_by_chat_bufnr(nil))
    end)
  end)

  describe("find_other_holding_session", function()
    -- A subagent chat shares its parent's session_id permanently, so two buffers can end up
    -- resuming one session; two CLI processes appending to that transcript would corrupt it (#756).
    it("finds another buffer's process on the same session", function()
      local registry = fresh_registry()
      registry.register({ process_id = "a", chat_bufnr = 11, session_id = "s-1", adapter = {} })

      local conflict = registry.find_other_holding_session("s-1", 12)
      assert.is_not_nil(conflict)
      assert.equals(11, conflict.chat_bufnr)
    end)

    it("counts an idle process as a holder", function()
      -- The whole reason this question is asked of processes and not of turns: a resident process
      -- keeps its `--resume <id>` between turns (#774), so "is another stream in flight" would let
      -- a second process attach to the same transcript the moment the first one went idle.
      local registry = fresh_registry()
      local TurnRegistry = require("vibing.infrastructure.adapter.modules.turn_registry")
      local process = { process_id = "a", chat_bufnr = 11, session_id = "s-1", adapter = {} }
      registry.register(process)
      TurnRegistry.open({ turn_id = "a-turn", process = process })
      TurnRegistry.close("a-turn")

      assert.is_nil(process.active_turn_id)
      assert.is_not_nil(registry.find_other_holding_session("s-1", 12))
    end)

    it("does not report a buffer's own process as a conflict", function()
      local registry = fresh_registry()
      registry.register({ process_id = "a", chat_bufnr = 11, session_id = "s-1", adapter = {} })

      assert.is_nil(registry.find_other_holding_session("s-1", 11))
    end)

    it("ignores processes on other sessions", function()
      local registry = fresh_registry()
      registry.register({ process_id = "a", chat_bufnr = 11, session_id = "s-1", adapter = {} })

      assert.is_nil(registry.find_other_holding_session("s-2", 12))
    end)

    it("reports nothing once that process has gone", function()
      local registry = fresh_registry()
      registry.register({ process_id = "a", chat_bufnr = 11, session_id = "s-1", adapter = {} })
      registry.unregister("a")

      assert.is_nil(registry.find_other_holding_session("s-1", 12))
    end)

    it("treats a chat with no session yet as unconflicted", function()
      local registry = fresh_registry()
      registry.register({ process_id = "a", chat_bufnr = 11, session_id = "s-1", adapter = {} })

      assert.is_nil(registry.find_other_holding_session(nil, 12))
      assert.is_nil(registry.find_other_holding_session("", 12))
    end)
  end)
end)
