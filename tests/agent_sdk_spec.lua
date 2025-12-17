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
      adapter = "agent_sdk",
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

    it("should initialize handle as nil", function()
      local adapter = AgentSDK:new(mock_config)
      assert.is_nil(adapter._handle)
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

    it("should include context files", function()
      local adapter = AgentSDK:new(mock_config)
      local cmd = adapter:build_command("test", {
        context = {
          "@file:src/main.lua",
          "@file:src/config.lua",
        },
      })

      local context_count = 0
      for i, arg in ipairs(cmd) do
        if arg == "--context" then
          context_count = context_count + 1
          local path = cmd[i + 1]
          assert.is_not_nil(path)
          assert.is_nil(path:match("^@file:"))
        end
      end
      assert.equals(2, context_count)
    end)

    it("should strip @file: prefix from context paths", function()
      local adapter = AgentSDK:new(mock_config)
      local cmd = adapter:build_command("test", {
        context = { "@file:test.lua" },
      })

      local found_path = false
      for i, arg in ipairs(cmd) do
        if arg == "--context" then
          assert.equals("test.lua", cmd[i + 1])
          found_path = true
        end
      end
      assert.is_true(found_path)
    end)

    it("should include permissions allow list", function()
      local adapter = AgentSDK:new(mock_config)
      local cmd = adapter:build_command("test", {})

      local has_allow = false
      for i, arg in ipairs(cmd) do
        if arg == "--allow" then
          has_allow = true
          local tools = cmd[i + 1]
          assert.is_not_nil(tools:match("Read"))
          assert.is_not_nil(tools:match("Edit"))
          assert.is_not_nil(tools:match("Write"))
        end
      end
      assert.is_true(has_allow)
    end)

    it("should include permissions deny list", function()
      local adapter = AgentSDK:new(mock_config)
      local cmd = adapter:build_command("test", {})

      local has_deny = false
      for i, arg in ipairs(cmd) do
        if arg == "--deny" then
          has_deny = true
          assert.is_not_nil(cmd[i + 1]:match("Bash"))
        end
      end
      assert.is_true(has_deny)
    end)

    it("should include prompt at the end", function()
      local adapter = AgentSDK:new(mock_config)
      local cmd = adapter:build_command("Hello World", {})

      assert.equals("--prompt", cmd[#cmd - 1])
      assert.equals("Hello World", cmd[#cmd])
    end)

    it("should handle empty context", function()
      local adapter = AgentSDK:new(mock_config)
      local cmd = adapter:build_command("test", {})

      local context_count = 0
      for _, arg in ipairs(cmd) do
        if arg == "--context" then
          context_count = context_count + 1
        end
      end
      assert.equals(0, context_count)
    end)

    it("should handle missing agent config gracefully", function()
      local config_no_agent = {
        adapter = "agent_sdk",
        permissions = mock_config.permissions,
      }
      local adapter = AgentSDK:new(config_no_agent)

      assert.has_no.errors(function()
        adapter:build_command("test", {})
      end)
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
    it("should store session id", function()
      local adapter = AgentSDK:new(mock_config)
      adapter:set_session_id("test-session-123")

      assert.equals("test-session-123", adapter._session_id)
    end)

    it("should include session id in command", function()
      local adapter = AgentSDK:new(mock_config)
      adapter:set_session_id("my-session")

      local cmd = adapter:build_command("test", {})

      local has_session = false
      for i, arg in ipairs(cmd) do
        if arg == "--session" then
          has_session = true
          assert.equals("my-session", cmd[i + 1])
        end
      end
      assert.is_true(has_session)
    end)
  end)
end)
