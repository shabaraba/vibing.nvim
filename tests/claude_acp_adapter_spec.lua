-- Tests for vibing.adapters.claude_acp module

describe("vibing.adapters.claude_acp", function()
  local ClaudeACPAdapter
  local mock_config

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.adapters.base"] = nil
    package.loaded["vibing.adapters.claude_acp"] = nil

    ClaudeACPAdapter = require("vibing.adapters.claude_acp")

    mock_config = {
      adapter = "claude_acp",
    }
  end)

  describe("new", function()
    it("should create claude_acp adapter instance", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      assert.is_not_nil(adapter)
      assert.equals("claude_acp", adapter.name)
    end)

    it("should initialize handle as nil", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      assert.is_nil(adapter._handle)
    end)

    it("should initialize state", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      assert.is_not_nil(adapter._state)
      assert.equals(1, adapter._state.next_id)
      assert.equals("", adapter._state.stdout_buffer)
      assert.same({}, adapter._state.pending)
      assert.is_nil(adapter._state.session_id)
    end)

    it("should store config reference", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      assert.equals(mock_config, adapter.config)
    end)
  end)

  describe("build_command", function()
    it("should return claude-code-acp command", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      local cmd = adapter:build_command()

      assert.equals(1, #cmd)
      assert.equals("claude-code-acp", cmd[1])
    end)
  end)

  describe("send_rpc", function()
    it("should increment next_id", function()
      local adapter = ClaudeACPAdapter:new(mock_config)

      -- Mock handle with write method
      adapter._handle = {
        write = function() end,
      }

      local initial_id = adapter._state.next_id
      adapter:send_rpc("test_method", {}, function() end)

      assert.equals(initial_id + 1, adapter._state.next_id)
    end)

    it("should store callback in pending", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      adapter._handle = {
        write = function() end,
      }

      local callback = function() end
      local id = adapter:send_rpc("test_method", {}, callback)

      assert.is_not_nil(adapter._state.pending[id])
    end)

    it("should not add callback when none provided", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      adapter._handle = {
        write = function() end,
      }

      adapter:send_rpc("test_method", {})

      -- Pending should be empty
      local count = 0
      for _ in pairs(adapter._state.pending) do
        count = count + 1
      end
      assert.equals(0, count)
    end)
  end)

  describe("send_notification", function()
    it("should send message without id when handle exists", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      local written_data = nil

      adapter._handle = {
        write = function(self, data)
          written_data = data
        end,
      }

      adapter:send_notification("test_notification", { foo = "bar" })

      -- Verify data was written and is properly formatted JSON-RPC
      assert.is_not_nil(written_data)
      assert.is_string(written_data)
      assert.is_not_nil(written_data:match('"jsonrpc"'))
      assert.is_not_nil(written_data:match('"test_notification"'))
      assert.is_nil(written_data:match('"id"'))
    end)

    it("should not error when no handle", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      adapter._handle = nil

      -- Should not error
      adapter:send_notification("test_notification", {})
    end)
  end)

  describe("handle_stdout", function()
    it("should buffer incomplete lines", function()
      local adapter = ClaudeACPAdapter:new(mock_config)

      adapter:handle_stdout("partial ", function() end)
      assert.equals("partial ", adapter._state.stdout_buffer)

      adapter:handle_stdout("line\n", function() end)
      assert.equals("", adapter._state.stdout_buffer)
    end)

    it("should process complete JSON lines", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      local messages = {}

      local original_handle = adapter.handle_rpc_message
      adapter.handle_rpc_message = function(self, msg, on_chunk)
        table.insert(messages, msg)
      end

      local json_line = vim.json.encode({ jsonrpc = "2.0", id = 1, result = "test" }) .. "\n"
      adapter:handle_stdout(json_line, function() end)

      assert.equals(1, #messages)
      assert.equals(1, messages[1].id)

      -- Restore
      adapter.handle_rpc_message = original_handle
    end)
  end)

  describe("handle_rpc_message", function()
    it("should call pending callback on response", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      local callback_called = false
      local callback_result = nil

      adapter._state.pending[1] = function(result, err)
        callback_called = true
        callback_result = result
      end

      adapter:handle_rpc_message({
        id = 1,
        result = { success = true },
      }, function() end)

      assert.is_true(callback_called)
      assert.same({ success = true }, callback_result)
      assert.is_nil(adapter._state.pending[1])
    end)

    it("should handle error responses", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      local callback_error = nil

      adapter._state.pending[1] = function(result, err)
        callback_error = err
      end

      adapter:handle_rpc_message({
        id = 1,
        error = { code = -1, message = "Test error" },
      }, function() end)

      assert.is_not_nil(callback_error)
      assert.equals("Test error", callback_error.message)
    end)
  end)

  describe("supports", function()
    it("should support streaming", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      assert.is_true(adapter:supports("streaming"))
    end)

    it("should support tools", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      assert.is_true(adapter:supports("tools"))
    end)

    it("should not support model_selection", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      assert.is_false(adapter:supports("model_selection"))
    end)

    it("should support context", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      assert.is_true(adapter:supports("context"))
    end)

    it("should not support unknown features", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      assert.is_false(adapter:supports("unknown_feature"))
    end)
  end)

  describe("cancel", function()
    it("should send cancel notification when session exists", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      local notification_sent = false

      adapter._state.session_id = "test-session-123"
      adapter._handle = {}

      local original_send = adapter.send_notification
      adapter.send_notification = function(self, method, params)
        notification_sent = true
        assert.equals("session/cancel", method)
        assert.equals("test-session-123", params.sessionId)
      end

      adapter:cancel()

      assert.is_true(notification_sent)

      -- Restore
      adapter.send_notification = original_send
    end)

    it("should not error when no handle", function()
      local adapter = ClaudeACPAdapter:new(mock_config)
      adapter._handle = nil

      -- Should not error
      adapter:cancel()
    end)
  end)
end)
