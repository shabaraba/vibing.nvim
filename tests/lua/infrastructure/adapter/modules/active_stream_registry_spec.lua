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
end)
