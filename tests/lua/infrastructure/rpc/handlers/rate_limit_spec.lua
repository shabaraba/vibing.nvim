local processes = require("vibing.infrastructure.adapter.modules.process_registry")
local registry = require("vibing.infrastructure.adapter.modules.turn_registry")

describe("rpc.handlers.rate_limit", function()
  ---@return table
  local function fresh_handler()
    package.loaded["vibing.infrastructure.rpc.handlers.rate_limit"] = nil
    return require("vibing.infrastructure.rpc.handlers.rate_limit")
  end

  --- The hook names a process; the failure is parked under the turn that process has open, because
  --- `wrapped_on_done` is what collects it and it knows the turn it is completing. So a spec has to
  --- register the join, and the two ids are deliberately different values.
  local registered = {}
  local function open_turn(name)
    local chat = { process_id = name .. "-process", turn_id = name .. "-turn" }
    local process = { process_id = chat.process_id }
    processes.register(process)
    registry.open({ turn_id = chat.turn_id, process = process })
    table.insert(registered, chat)
    return chat
  end

  after_each(function()
    for _, chat in ipairs(registered) do
      registry.close(chat.turn_id)
      processes.unregister(chat.process_id)
    end
    registered = {}
  end)

  it("returns nil when nothing was recorded", function()
    local handler = fresh_handler()
    assert.is_nil(handler.take_failure("turn-1"))
  end)

  it("rejects a request without request_id", function()
    local handler = fresh_handler()
    local res = handler.stop_failure({})
    assert.equals("error", res.status)
  end)

  it("ignores a payload file that does not exist", function()
    local handler = fresh_handler()
    local res = handler.stop_failure({ request_id = "does-not-exist", process_id = "p" })
    assert.equals("ignored", res.status)
  end)

  describe("with a payload file on disk", function()
    local CommDir = require("vibing.infrastructure.rpc.comm_dir")
    local comm_dir
    local saved_env

    before_each(function()
      -- Without an override the handler resolves /tmp/vibing-hook-0 here (no RPC port in tests),
      -- which every parallel plenary job would share — they would then read and delete each
      -- other's payload files.
      saved_env = vim.env[CommDir.ENV_VAR]
      comm_dir = vim.fn.tempname() .. "/vibing-hook"
      vim.env[CommDir.ENV_VAR] = comm_dir
    end)

    after_each(function()
      pcall(vim.fn.delete, comm_dir, "rf")
      vim.env[CommDir.ENV_VAR] = saved_env
    end)

    ---Write a hook payload where the handler expects to find it.
    ---@param request_id string
    ---@param payload table
    local function write_payload(request_id, payload)
      vim.fn.mkdir(comm_dir, "p")
      vim.fn.writefile({ vim.json.encode(payload) }, comm_dir .. "/" .. request_id .. ".fail")
    end

    it("records a rate_limit failure and parks it under the turn, not the process", function()
      local handler = fresh_handler()
      local chat = open_turn("a")
      write_payload("req-rl", { hook_event_name = "StopFailure", error_type = "rate_limit" })

      local res = handler.stop_failure({ request_id = "req-rl", process_id = chat.process_id })
      assert.equals("ok", res.status)

      -- `wrapped_on_done` collects this with the turn id it is completing, so the process id must
      -- not address it: under a resident process one process outlives many turns.
      assert.is_nil(handler.take_failure(chat.process_id))
      local info = handler.take_failure(chat.turn_id)
      assert.is_not_nil(info)
      assert.is_true(info.rejected)
      -- Consumed, not merely peeked: a stale failure must not leak into the next turn.
      assert.is_nil(handler.take_failure(chat.turn_id))
    end)

    it("does not hand one chat's failure to another concurrent chat", function()
      local handler = fresh_handler()
      local a, b = open_turn("chat-a"), open_turn("chat-b")
      write_payload("req-a", { error_type = "rate_limit" })
      write_payload("req-b", { error_type = "rate_limit" })
      handler.stop_failure({ request_id = "req-a", process_id = a.process_id })
      handler.stop_failure({ request_id = "req-b", process_id = b.process_id })

      assert.is_not_nil(handler.take_failure(a.turn_id))
      assert.is_not_nil(handler.take_failure(b.turn_id))
    end)

    it("drops an unnamed failure even when exactly one chat is live (regression)", function()
      -- **The single-chat case is the common case, and it is the one that costs money.** This
      -- handler refuses `hook_scope`'s sole-active guess, unlike the permission handler: an
      -- unattributed rate limit written onto the only running chat sets a project-wide limit state
      -- for that backend and hands its message to auto-resume, which then spends tokens on a chat
      -- that was never rate-limited.
      local handler = fresh_handler()
      local only = open_turn("only")
      write_payload("req-unkeyed", { error_type = "rate_limit" })

      local res = handler.stop_failure({ request_id = "req-unkeyed", process_id = "" })
      assert.equals("ignored", res.status)
      assert.is_nil(handler.take_failure(only.turn_id))
    end)

    it("drops an unnamed failure when several chats are live", function()
      local handler = fresh_handler()
      local a, b = open_turn("chat-a"), open_turn("chat-b")
      write_payload("req-unkeyed-multi", { error_type = "rate_limit" })

      local res = handler.stop_failure({ request_id = "req-unkeyed-multi", process_id = "" })
      assert.equals("ignored", res.status)

      -- Neither concurrent chat may inherit it: doing so would auto-resume a healthy chat.
      assert.is_nil(handler.take_failure(a.turn_id))
      assert.is_nil(handler.take_failure(b.turn_id))
      assert.is_nil(handler.take_failure(nil))
    end)

    it("drops a failure from a process nothing has registered", function()
      -- The case the old code could not tell apart from the one above: an id that is present but
      -- matches nothing. `hook_scope` refuses to fall back for it, so a straggler from an already
      -- finished turn cannot be attributed to whoever is running now.
      local handler = fresh_handler()
      local live = open_turn("live")
      write_payload("req-stale", { error_type = "rate_limit" })

      local res = handler.stop_failure({ request_id = "req-stale", process_id = "a-process-that-died" })
      assert.equals("ignored", res.status)
      assert.is_nil(handler.take_failure(live.turn_id))
    end)

    it("ignores non-rate-limit API errors", function()
      local handler = fresh_handler()
      local chat = open_turn("b")
      write_payload("req-overloaded", { error_type = "overloaded" })

      local res = handler.stop_failure({ request_id = "req-overloaded", process_id = chat.process_id })
      assert.equals("ignored", res.status)
      assert.is_nil(handler.take_failure(chat.turn_id))
    end)

    it("deletes the payload file after reading it", function()
      local handler = fresh_handler()
      local chat = open_turn("c")
      write_payload("req-cleanup", { error_type = "rate_limit" })
      handler.stop_failure({ request_id = "req-cleanup", process_id = chat.process_id })

      assert.equals(0, vim.fn.filereadable(comm_dir .. "/req-cleanup.fail"))
    end)
  end)
end)
