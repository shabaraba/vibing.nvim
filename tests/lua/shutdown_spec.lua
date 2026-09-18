---@diagnostic disable: undefined-field
--- What `VimLeavePre` does, and in which order.
---
--- The order is the specification, not an implementation detail. A hook blocked on an unanswered
--- approval (#778) is a CLI process sitting inside `pre-tool-use.sh`, and the only thing that can
--- release it is a `.res` file written by us. Exiting without writing one leaves that hook polling
--- to its own deadline — so the release has to happen while we can still do it: before the CLI
--- processes are cancelled, and before the RPC server stops and `comm_dir` loses the port its path
--- is built from.
local Pending = require("vibing.infrastructure.rpc.pending_approvals")
local Vibing = require("vibing")

describe("shutdown", function()
  local order
  local restore

  before_each(function()
    order = {}
    Pending._reset()

    local job_manager = require("vibing.application.job.manager")
    local rpc_server = require("vibing.infrastructure.rpc.server")
    local original = {
      job_shutdown = job_manager.shutdown,
      resolve_all = Pending.resolve_all,
      rpc_stop = rpc_server.stop,
      adapter = Vibing.adapter,
      config = Vibing.config,
    }

    ---@diagnostic disable-next-line: duplicate-set-field
    job_manager.shutdown = function()
      table.insert(order, "jobs")
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    Pending.resolve_all = function(reason)
      table.insert(order, "approvals")
      return original.resolve_all(reason)
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    rpc_server.stop = function()
      table.insert(order, "rpc")
    end
    Vibing.adapter = {
      cancel = function()
        table.insert(order, "cli")
      end,
    }
    Vibing.config = { mcp = { enabled = true } }

    restore = function()
      job_manager.shutdown = original.job_shutdown
      Pending.resolve_all = original.resolve_all
      rpc_server.stop = original.rpc_stop
      Vibing.adapter = original.adapter
      Vibing.config = original.config
    end
  end)

  after_each(function()
    restore()
    Pending._reset()
  end)

  it("releases the blocked hooks before killing the CLI that is waiting in them", function()
    Vibing._shutdown()

    local approvals = vim.fn.index(order, "approvals")
    local cli = vim.fn.index(order, "cli")
    assert.is_true(approvals >= 0, "pending approvals were never released: " .. vim.inspect(order))
    assert.is_true(
      approvals < cli,
      "a killed CLI can no longer stop waiting, so the hook must be released first: " .. vim.inspect(order)
    )
  end)

  it("releases them before the RPC server stops, since comm_dir is keyed by its port", function()
    Vibing._shutdown()
    assert.is_true(
      vim.fn.index(order, "approvals") < vim.fn.index(order, "rpc"),
      "the .res path is built from the RPC port: " .. vim.inspect(order)
    )
  end)

  it("stops Neovim-owned jobs first, so no completion wakes a new turn mid-exit", function()
    Vibing._shutdown()
    assert.equals(1, vim.fn.index(order, "jobs") + 1)
  end)

  it("runs every later step even when an earlier one throws", function()
    -- A shutdown that stops at the first error is one that silently skips the rest, and the step
    -- most likely to throw (an adapter mid-teardown) sits in the middle of the ones that matter.
    Vibing.adapter = {
      cancel = function()
        table.insert(order, "cli")
        error("adapter blew up during teardown")
      end,
    }
    Vibing._shutdown()
    assert.same({ "jobs", "approvals", "cli", "rpc" }, order)
  end)

  it("writes a deny for every hook that was still waiting", function()
    -- End to end rather than through the stub: the point of the ordering is that these files exist
    -- by the time the CLI is gone.
    local comm_dir = vim.fn.tempname()
    vim.fn.mkdir(comm_dir, "p")
    vim.env.VIBING_HOOK_COMM_DIR = comm_dir

    local ok, err = pcall(function()
      Pending.open({ request_id = "exit-1", chat_bufnr = 7, tool = "Bash" })
      Vibing._shutdown()

      local f = assert(io.open(comm_dir .. "/exit-1.res", "r"), "no response was written for a waiting hook")
      local decoded = vim.json.decode(f:read("*a"))
      f:close()
      assert.equals("deny", decoded.hookSpecificOutput.permissionDecision)
      assert.is_truthy(decoded.hookSpecificOutput.permissionDecisionReason)
      assert.equals(0, Pending.count())
    end)

    vim.env.VIBING_HOOK_COMM_DIR = nil
    vim.fn.delete(comm_dir, "rf")
    assert.is_true(ok, tostring(err))
  end)

  it("replies to every question that was still waiting, in the same step", function()
    -- The other channel a human is waited for on (#788), and the one whose absence is invisible:
    -- a withheld hook response times out inside `pre-tool-use.sh`, but a withheld MCP reply leaves
    -- the CLI inside the tool call until its own idle limit — 1800s on claude, with nothing on
    -- screen to say so. Both are released by one step for exactly that reason, so this pins that
    -- the question half actually runs and runs before the CLI is cancelled.
    local Questions = require("vibing.infrastructure.rpc.pending_questions")
    Questions._reset()

    local replies = {}
    Questions.open({
      request_id = "exit-q-1",
      chat_bufnr = 7,
      questions = { { question = "Which approach?" } },
      respond = function(result)
        table.insert(replies, result)
        table.insert(order, "questions")
      end,
    })

    Vibing._shutdown()
    Questions._reset()

    assert.equals(1, #replies, "the waiting MCP call was never answered: " .. vim.inspect(order))
    assert.equals("unanswered", replies[1].status)
    assert.is_true(
      vim.fn.index(order, "questions") < vim.fn.index(order, "cli"),
      "a killed CLI can no longer stop waiting, so the reply must be written first: " .. vim.inspect(order)
    )
  end)
end)
