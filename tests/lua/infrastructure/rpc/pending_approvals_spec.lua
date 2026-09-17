---@diagnostic disable: undefined-field
--- A withheld `.res` is a CLI process sitting inside its own hook, so the contract of this registry
--- is not "remember some approvals" — it is **every entry is eventually written**. A leak here is a
--- turn that hangs until the hook's own deadline and then denies with a generic message, which is
--- worse than either design on its own.
local Config = require("vibing.config")
local HookResponse = require("vibing.infrastructure.rpc.hook_response")
local Pending = require("vibing.infrastructure.rpc.pending_approvals")

local comm_dir

--- @param request_id string
--- @return table|nil
local function read_response(request_id)
  local f = io.open(HookResponse.path(request_id), "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, content)
  return ok and decoded or nil
end

--- @param request_id string
--- @return string|nil
local function decision_of(request_id)
  local decoded = read_response(request_id)
  return decoded and decoded.hookSpecificOutput and decoded.hookSpecificOutput.permissionDecision
end

describe("pending_approvals", function()
  before_each(function()
    comm_dir = vim.fn.tempname()
    vim.fn.mkdir(comm_dir, "p")
    vim.env.VIBING_HOOK_COMM_DIR = comm_dir
    Pending._reset()
  end)

  after_each(function()
    Pending._reset()
    vim.env.VIBING_HOOK_COMM_DIR = nil
    vim.fn.delete(comm_dir, "rf")
  end)

  it("withholds the response until something answers", function()
    -- The whole mechanism in one assertion: opening writes nothing, so the hook keeps polling and
    -- the CLI stays alive inside it.
    Pending.open({ request_id = "r1", chat_bufnr = 7, tool = "Bash" })
    assert.is_nil(read_response("r1"))
    assert.equals(1, Pending.count())
  end)

  it("writes the answer it is given and forgets the entry", function()
    Pending.open({ request_id = "r1", chat_bufnr = 7 })
    assert.is_true(Pending.resolve("r1", "defer"))
    assert.equals("defer", decision_of("r1"))
    assert.equals(0, Pending.count())
  end)

  it("carries a deny's reason, which is the only way it reaches the model", function()
    Pending.open({ request_id = "r1", chat_bufnr = 7 })
    Pending.resolve("r1", "deny", "because")
    assert.equals("because", read_response("r1").hookSpecificOutput.permissionDecisionReason)
  end)

  it("answers a request only once", function()
    -- Two writers race by construction here: a human answering in the same tick a timer fires. The
    -- second must be a no-op rather than a second decision written over the first.
    Pending.open({ request_id = "r1", chat_bufnr = 7 })
    assert.is_true(Pending.resolve("r1", "allow"))
    assert.is_false(Pending.resolve("r1", "deny"))
    assert.equals("allow", decision_of("r1"))
  end)

  it("reports nothing to answer for a request it never had", function()
    assert.is_false(Pending.resolve("never-opened", "deny"))
    assert.is_nil(read_response("never-opened"))
  end)

  describe("the wait limit", function()
    local original

    before_each(function()
      original = Config.get().permissions.approval_wait_sec
    end)

    after_each(function()
      Config.get().permissions.approval_wait_sec = original
    end)

    it("denies and runs the fallback when nobody answers", function()
      -- The smallest configurable wait is 30 real seconds, so the timer is not waited out. What is
      -- called is the production function the timer calls, not a re-enactment of it in the test —
      -- the wiring from one to the other is the next assertion's job.
      local fired = {}
      Pending.open({
        request_id = "r1",
        chat_bufnr = 7,
        tool = "Bash",
        on_timeout = function(entry)
          -- The hook must already have been released by the time the fallback kills the turn, or
          -- an orphaned pre-tool-use.sh polls for a process that no longer exists.
          table.insert(fired, { entry.request_id, decision_of(entry.request_id) })
        end,
      })

      assert.is_true(Pending.expire("r1"))
      assert.equals("deny", decision_of("r1"))
      assert.same({ { "r1", "deny" } }, fired)
      assert.equals(0, Pending.count())

      local reason = read_response("r1").hookSpecificOutput.permissionDecisionReason
      assert.is_truthy(reason:find("Bash", 1, true), "the timeout reason must name the tool: " .. reason)
    end)

    it("is what the armed timer actually calls", function()
      -- Otherwise `expire` is a function the suite exercises and the product never reaches. The
      -- callback is captured rather than waited for, which is the only part of the timer worth
      -- testing: vim.fn.timer_start firing after its delay is not ours.
      local captured
      local original_start = vim.fn.timer_start
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.timer_start = function(delay, callback)
        captured = callback
        return original_start(delay, function() end)
      end
      local ok, err = pcall(function()
        Pending.open({ request_id = "r1", chat_bufnr = 7, tool = "Bash" })
      end)
      vim.fn.timer_start = original_start
      assert.is_true(ok, tostring(err))

      assert.is_function(captured)
      captured()
      assert.equals("deny", decision_of("r1"))
      assert.equals(0, Pending.count())
    end)

    it("does nothing when the human answered first", function()
      Pending.open({ request_id = "r1", chat_bufnr = 7 })
      Pending.resolve("r1", "allow")
      assert.is_false(Pending.expire("r1"))
      assert.equals("allow", decision_of("r1"))
    end)

    it("arms the timer from the configured wait, not a constant", function()
      Config.get().permissions.approval_wait_sec = 45
      Pending.open({ request_id = "r1", chat_bufnr = 7 })
      local remaining = vim.fn.timer_info(Pending.get("r1")._timer)[1]
      assert.equals(45000, remaining.time)
    end)

    it("stops the timer when the answer arrives, so it cannot fire into a finished turn", function()
      Pending.open({ request_id = "r1", chat_bufnr = 7 })
      local timer = Pending.get("r1")._timer
      Pending.resolve("r1", "allow")
      assert.same({}, vim.fn.timer_info(timer))
    end)
  end)

  describe("more than one hook blocked at once", function()
    it("keeps them apart by request id, not by chat", function()
      -- A CLI may have several tool calls in flight, and copilot re-runs a hook it cut. Both give
      -- one chat two blocked hooks, and answering one must not release the other.
      Pending.open({ request_id = "r1", chat_bufnr = 7 })
      Pending.open({ request_id = "r2", chat_bufnr = 7 })
      Pending.resolve("r1", "allow")
      assert.equals("allow", decision_of("r1"))
      assert.is_nil(read_response("r2"))
      assert.equals(1, Pending.count())
    end)

    it("lists one chat's blocked hooks oldest first, and no other chat's", function()
      Pending.open({ request_id = "r1", chat_bufnr = 7 })
      Pending.open({ request_id = "r2", chat_bufnr = 9 })
      Pending.open({ request_id = "r3", chat_bufnr = 7 })

      local mine = Pending.list_for_chat(7)
      assert.equals(2, #mine)
      assert.is_true(mine[1].opened_at <= mine[2].opened_at)
      for _, entry in ipairs(mine) do
        assert.equals(7, entry.chat_bufnr)
      end
    end)

    it("denies a reopened request id rather than losing its timer", function()
      Pending.open({ request_id = "r1", chat_bufnr = 7 })
      local first = Pending.get("r1")._timer
      Pending.open({ request_id = "r1", chat_bufnr = 7 })
      assert.same({}, vim.fn.timer_info(first))
      assert.equals("deny", decision_of("r1"))
      assert.equals(1, Pending.count())
    end)
  end)

  describe("cleanup", function()
    it("denies every hook waiting on a chat that went away", function()
      Pending.open({ request_id = "r1", chat_bufnr = 7 })
      Pending.open({ request_id = "r2", chat_bufnr = 7 })
      Pending.open({ request_id = "r3", chat_bufnr = 9 })

      assert.equals(2, Pending.resolve_for_chat(7, "the chat was closed"))
      assert.equals("deny", decision_of("r1"))
      assert.equals("deny", decision_of("r2"))
      assert.is_nil(read_response("r3"))
    end)

    it("denies everything left when Neovim exits", function()
      -- Without this the hook polls to its own deadline after we are gone, and the user's next
      -- glance at that terminal shows a CLI that appears hung.
      Pending.open({ request_id = "r1", chat_bufnr = 7 })
      Pending.open({ request_id = "r2", chat_bufnr = 9 })
      assert.equals(2, Pending.resolve_all("Neovim exited"))
      assert.equals("deny", decision_of("r1"))
      assert.equals("deny", decision_of("r2"))
      assert.equals(0, Pending.count())
    end)

    it("is a no-op with nothing pending", function()
      assert.equals(0, Pending.resolve_all("Neovim exited"))
      assert.equals(0, Pending.resolve_for_chat(7, "closed"))
    end)
  end)
end)
