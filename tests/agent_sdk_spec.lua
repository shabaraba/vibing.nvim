-- Tests for vibing.adapters.agent_sdk module

describe("vibing.adapters.agent_sdk", function()
  local AgentSDK
  local mock_config

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.adapters.base"] = nil
    package.loaded["vibing.adapters.agent_sdk"] = nil
    package.loaded["vibing"] = nil

    AgentSDK = require("vibing.adapters.agent_sdk")

    mock_config = {
      agent = {
        default_mode = "code",
        default_model = "sonnet",
      },
      permissions = {
        allow = { "Read", "Edit", "Write" },
        deny = { "Bash" },
      },
    }

    -- Mock vibing module for permissions
    package.loaded["vibing"] = {
      get_config = function()
        return mock_config
      end,
    }
  end)

  describe("new", function()
    it("should create agent_sdk adapter instance", function()
      local adapter = AgentSDK:new(mock_config)
      assert.is_not_nil(adapter)
      assert.equals("agent_sdk", adapter.name)
    end)

    it("should initialize plugin root path", function()
      local adapter = AgentSDK:new(mock_config)
      assert.is_not_nil(adapter._plugin_root)
      assert.is_string(adapter._plugin_root)
    end)

    it("should initialize handles as empty table", function()
      local adapter = AgentSDK:new(mock_config)
      assert.is_table(adapter._handles)
      assert.equals(0, vim.tbl_count(adapter._handles))
    end)

    it("should initialize sessions as empty table", function()
      local adapter = AgentSDK:new(mock_config)
      assert.is_table(adapter._sessions)
      assert.equals(0, vim.tbl_count(adapter._sessions))
    end)

    it("should store config reference", function()
      local adapter = AgentSDK:new(mock_config)
      assert.equals(mock_config, adapter.config)
    end)
  end)

  describe("get_wrapper_path", function()
    it("should return wrapper script path", function()
      local adapter = AgentSDK:new(mock_config)
      local path = adapter:get_wrapper_path()

      assert.is_not_nil(path)
      assert.is_not_nil(path:match("bin/agent%-wrapper%.mjs$"))
    end)
  end)

  describe("build_command", function()
    it("should include node and wrapper path", function()
      local adapter = AgentSDK:new(mock_config)
      local cmd = adapter:build_command("test prompt", {})

      assert.equals("node", cmd[1])
      assert.is_not_nil(cmd[2]:match("agent%-wrapper%.mjs"))
    end)

    it("should include cwd argument", function()
      local adapter = AgentSDK:new(mock_config)
      local cmd = adapter:build_command("test", {})

      local has_cwd = false
      for i, arg in ipairs(cmd) do
        if arg == "--cwd" then
          has_cwd = true
          assert.is_not_nil(cmd[i + 1])
        end
      end
      assert.is_true(has_cwd)
    end)

    it("should include mode from config", function()
      local adapter = AgentSDK:new(mock_config)
      local cmd = adapter:build_command("test", {})

      local has_mode = false
      for i, arg in ipairs(cmd) do
        if arg == "--mode" then
          has_mode = true
          assert.equals("code", cmd[i + 1])
        end
      end
      assert.is_true(has_mode)
    end)

    it("should include model from config", function()
      local adapter = AgentSDK:new(mock_config)
      local cmd = adapter:build_command("test", {})

      local has_model = false
      for i, arg in ipairs(cmd) do
        if arg == "--model" then
          has_model = true
          assert.equals("sonnet", cmd[i + 1])
        end
      end
      assert.is_true(has_model)
    end)

    it("should include prompt at the end", function()
      local adapter = AgentSDK:new(mock_config)
      local cmd = adapter:build_command("Hello World", {})

      assert.equals("--prompt", cmd[#cmd - 1])
      assert.equals("Hello World", cmd[#cmd])
    end)
  end)

  describe("supports", function()
    it("should support streaming", function()
      local adapter = AgentSDK:new(mock_config)
      assert.is_true(adapter:supports("streaming"))
    end)

    it("should support session", function()
      local adapter = AgentSDK:new(mock_config)
      assert.is_true(adapter:supports("session"))
    end)

    it("should not support unknown features", function()
      local adapter = AgentSDK:new(mock_config)
      assert.is_false(adapter:supports("unknown_feature"))
    end)
  end)

  describe("set_session_id", function()
    it("should store session id in default key", function()
      local adapter = AgentSDK:new(mock_config)
      adapter:set_session_id("test-session-123")

      assert.equals("test-session-123", adapter:get_session_id())
    end)

    it("should store session id with handle_id", function()
      local adapter = AgentSDK:new(mock_config)
      adapter:set_session_id("test-session-456", "handle-1")

      assert.equals("test-session-456", adapter:get_session_id("handle-1"))
      assert.is_nil(adapter:get_session_id("handle-2"))
    end)

    it("should clear session id when set to nil", function()
      local adapter = AgentSDK:new(mock_config)
      adapter:set_session_id("test-session-123")
      adapter:set_session_id(nil)

      assert.is_nil(adapter:get_session_id())
    end)
  end)

  describe("cleanup_stale_sessions", function()
    it("should remove completed session while preserving active ones", function()
      local adapter = AgentSDK:new(mock_config)

      -- 複数のセッションを設定
      adapter._sessions["handle-1"] = "session-1"
      adapter._sessions["handle-2"] = "session-2"
      adapter._sessions["handle-3"] = "session-3"

      -- handle-2 のみ実行中とマーク
      adapter._handles["handle-2"] = {}

      -- クリーンアップ実行
      adapter:cleanup_stale_sessions()

      -- 実行中のセッションは保持、完了済みは削除
      assert.is_nil(adapter._sessions["handle-1"])
      assert.equals("session-2", adapter._sessions["handle-2"])
      assert.is_nil(adapter._sessions["handle-3"])
    end)

    it("should preserve __default__ key", function()
      local adapter = AgentSDK:new(mock_config)

      adapter._sessions["__default__"] = "default-session"
      adapter._sessions["handle-1"] = "session-1"

      adapter:cleanup_stale_sessions()

      assert.equals("default-session", adapter._sessions["__default__"])
      assert.is_nil(adapter._sessions["handle-1"])
    end)
  end)

  describe("concurrent requests", function()
    it("should handle multiple simultaneous sessions", function()
      local adapter = AgentSDK:new(mock_config)

      -- 複数のハンドルIDを生成して、セッションIDを設定
      adapter._sessions["handle-1"] = "session-1"
      adapter._sessions["handle-2"] = "session-2"
      adapter._sessions["handle-3"] = "session-3"

      -- すべてのセッションが独立して管理されていることを確認
      assert.equals("session-1", adapter:get_session_id("handle-1"))
      assert.equals("session-2", adapter:get_session_id("handle-2"))
      assert.equals("session-3", adapter:get_session_id("handle-3"))
    end)

    it("should cleanup specific handle without affecting others", function()
      local adapter = AgentSDK:new(mock_config)

      adapter._sessions["handle-1"] = "session-1"
      adapter._sessions["handle-2"] = "session-2"

      -- handle-1 のみクリーンアップ
      adapter:cleanup_session("handle-1")

      assert.is_nil(adapter:get_session_id("handle-1"))
      assert.equals("session-2", adapter:get_session_id("handle-2"))
    end)
  end)
end)
