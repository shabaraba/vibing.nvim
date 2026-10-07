---@diagnostic disable: undefined-field
--- `backends.codex.auto_approve`: answering codex's own sandbox-escape request from configuration.
---
--- The flag removes the **second** ask about a call vibing's PreToolUse hook already allowed — codex
--- sends no approval request at all when that hook denies — so these assertions guard three things:
--- that it answers with no chat to draw in, that it owes the registry nothing afterwards, and that a
--- request it has nothing to say about still reaches a human instead of being refused.
local MODULE = "vibing.infrastructure.adapter.modules.codex_native_approval"
local STUBBED = {
  "vibing.config",
  "vibing.infrastructure.adapter.modules.duplex_process",
  "vibing.infrastructure.rpc.pending_native_approvals",
  MODULE,
}

describe("codex native approval, auto_approve", function()
  local NativeApproval, written, opened

  --- @param codex table|nil what `backends.codex` holds for this test
  local function load(codex)
    written, opened = {}, {}
    package.loaded["vibing.config"] = {
      get = function()
        return { backends = { codex = codex } }
      end,
    }
    package.loaded["vibing.infrastructure.adapter.modules.duplex_process"] = {
      write_to = function(job_id, payload)
        table.insert(written, { job_id = job_id, payload = payload })
        return true
      end,
    }
    package.loaded["vibing.infrastructure.rpc.pending_native_approvals"] = {
      KIND = "native",
      open = function(entry)
        table.insert(opened, entry)
      end,
    }
    package.loaded[MODULE] = nil
    NativeApproval = require(MODULE)
  end

  after_each(function()
    for _, name in ipairs(STUBBED) do
      package.loaded[name] = nil
    end
  end)

  --- A process record carrying **no turn**, which is the state a request arriving with nowhere to
  --- ask is in. Today that is declined; the point of answering before the turn lookup is that this
  --- record is enough.
  local function record()
    return { job_id = 11, process_id = "p1" }
  end

  --- @param available any[]|nil codex's own `availableDecisions`
  local function request(available)
    return {
      id = 0,
      method = "item/commandExecution/requestApproval",
      params = { command = "git stash push", cwd = "/repo", availableDecisions = available },
    }
  end

  describe("when it is on", function()
    it("answers accept as the JSON-RPC response to the request codex sent", function()
      load({ auto_approve = true })

      local handled = NativeApproval.handle(record(), request({ "accept", "cancel" }))

      assert.is_true(handled)
      assert.same({ { job_id = 11, payload = { id = 0, result = { decision = "accept" } } } }, written)
    end)

    it("answers with no chat and no turn, where the human path would have declined", function()
      -- `handle` returns false for a record with no turn, and the caller refuses on false. The auto
      -- answer sits above that lookup precisely so a missing chat stops costing the user a call.
      load({ auto_approve = true })

      assert.is_true(NativeApproval.handle(record(), request(nil)))
      assert.equals("accept", written[1].payload.result.decision)
    end)

    it("owes the pending registry nothing, because the request is already answered", function()
      -- Opening an entry only to close it in the same tick would arm the wait limit against a
      -- decision that has already been written.
      load({ auto_approve = true })

      NativeApproval.handle(record(), request({ "accept" }))

      assert.same({}, opened)
    end)

    it("still asks when codex offered nothing that would let the call run", function()
      load({ auto_approve = true })

      local handled = NativeApproval.handle(record(), request({ "cancel" }))

      assert.is_false(handled)
      assert.same({}, written)
    end)

    it("takes the human path for a command auto_approve_ask names", function()
      -- The exception list can only ever send a request *to* a human; `handle` falls through to
      -- the turn lookup, which this record has nothing for, so nothing is written.
      load({ auto_approve = true, auto_approve_ask = { "Bash(git stash)" } })

      local handled = NativeApproval.handle(record(), request({ "accept" }))

      assert.is_false(handled)
      assert.same({}, written)
    end)

    it("auto-answers a command the exception list does not name", function()
      load({ auto_approve = true, auto_approve_ask = { "Bash(rm:*)" } })

      assert.is_true(NativeApproval.handle(record(), request({ "accept" })))
      assert.equals("accept", written[1].payload.result.decision)
    end)
  end)

  describe("when it is off", function()
    it("writes no decision of its own, so the request takes the human path", function()
      load({ auto_approve = false })

      assert.is_false(NativeApproval.handle(record(), request({ "accept", "cancel" })))
      assert.same({}, written)
    end)

    it("is off when the user set nothing, which is the default", function()
      load(nil)

      assert.is_false(NativeApproval.auto_approve_enabled())
      assert.is_false(NativeApproval.handle(record(), request({ "accept" })))
      assert.same({}, written)
    end)
  end)
end)
