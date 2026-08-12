describe("rpc.handlers.rate_limit", function()
  ---@return table
  local function fresh_handler()
    package.loaded["vibing.infrastructure.rpc.handlers.rate_limit"] = nil
    return require("vibing.infrastructure.rpc.handlers.rate_limit")
  end

  it("returns nil when nothing was recorded", function()
    local handler = fresh_handler()
    assert.is_nil(handler.take_failure("handle-1"))
  end)

  it("rejects a request without request_id", function()
    local handler = fresh_handler()
    local res = handler.stop_failure({})
    assert.equals("error", res.status)
  end)

  it("ignores a payload file that does not exist", function()
    local handler = fresh_handler()
    local res = handler.stop_failure({ request_id = "does-not-exist", handle_id = "h" })
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

    it("records a rate_limit failure and hands it to the matching handle", function()
      local handler = fresh_handler()
      write_payload("req-rl", { hook_event_name = "StopFailure", error_type = "rate_limit" })

      local res = handler.stop_failure({ request_id = "req-rl", handle_id = "handle-a" })
      assert.equals("ok", res.status)

      local info = handler.take_failure("handle-a")
      assert.is_not_nil(info)
      assert.is_true(info.rejected)
      -- Consumed, not merely peeked: a stale failure must not leak into the next turn.
      assert.is_nil(handler.take_failure("handle-a"))
    end)

    it("does not hand one chat's failure to another concurrent chat", function()
      local handler = fresh_handler()
      write_payload("req-a", { error_type = "rate_limit" })
      write_payload("req-b", { error_type = "rate_limit" })
      handler.stop_failure({ request_id = "req-a", handle_id = "chat-a" })
      handler.stop_failure({ request_id = "req-b", handle_id = "chat-b" })

      assert.is_not_nil(handler.take_failure("chat-a"))
      assert.is_not_nil(handler.take_failure("chat-b"))
    end)

    it("drops a failure with no handle_id instead of attributing it to a chat (regression)", function()
      local handler = fresh_handler()
      write_payload("req-unkeyed", { error_type = "rate_limit" })

      local res = handler.stop_failure({ request_id = "req-unkeyed", handle_id = "" })
      assert.equals("ignored", res.status)

      -- Neither concurrent chat may inherit it: doing so would auto-resume a healthy chat.
      assert.is_nil(handler.take_failure("chat-a"))
      assert.is_nil(handler.take_failure("chat-b"))
      assert.is_nil(handler.take_failure(nil))
    end)

    it("ignores non-rate-limit API errors", function()
      local handler = fresh_handler()
      write_payload("req-overloaded", { error_type = "overloaded" })

      local res = handler.stop_failure({ request_id = "req-overloaded", handle_id = "handle-b" })
      assert.equals("ignored", res.status)
      assert.is_nil(handler.take_failure("handle-b"))
    end)

    it("deletes the payload file after reading it", function()
      local handler = fresh_handler()
      write_payload("req-cleanup", { error_type = "rate_limit" })
      handler.stop_failure({ request_id = "req-cleanup", handle_id = "handle-c" })

      assert.equals(0, vim.fn.filereadable(comm_dir .. "/req-cleanup.fail"))
    end)
  end)
end)
