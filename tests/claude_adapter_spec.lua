-- Tests for vibing.adapters.claude module

describe("vibing.adapters.claude", function()
  local ClaudeAdapter
  local mock_config

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.adapters.base"] = nil
    package.loaded["vibing.adapters.claude"] = nil

    ClaudeAdapter = require("vibing.adapters.claude")

    mock_config = {
      adapter = "claude",
      cli_path = "/usr/local/bin/claude",
    }
  end)

  describe("new", function()
    it("should create claude adapter instance", function()
      local adapter = ClaudeAdapter:new(mock_config)
      assert.is_not_nil(adapter)
      assert.equals("claude", adapter.name)
    end)

    it("should store config reference", function()
      local adapter = ClaudeAdapter:new(mock_config)
      assert.equals(mock_config, adapter.config)
    end)

    it("should initialize job_id as nil", function()
      local adapter = ClaudeAdapter:new(mock_config)
      assert.is_nil(adapter.job_id)
    end)
  end)

  describe("build_command", function()
    it("should include cli_path and --print flag", function()
      local adapter = ClaudeAdapter:new(mock_config)
      local cmd = adapter:build_command("test prompt", {})

      assert.equals("/usr/local/bin/claude", cmd[1])
      assert.equals("--print", cmd[2])
    end)

    it("should include prompt at the end", function()
      local adapter = ClaudeAdapter:new(mock_config)
      local cmd = adapter:build_command("Hello World", {})

      assert.equals("Hello World", cmd[#cmd])
    end)

    it("should add verbose and stream-json flags when streaming", function()
      local adapter = ClaudeAdapter:new(mock_config)
      local cmd = adapter:build_command("test", { streaming = true })

      local has_verbose = false
      local has_format = false
      for i, arg in ipairs(cmd) do
        if arg == "--verbose" then
          has_verbose = true
        end
        if arg == "--output-format" then
          has_format = true
          assert.equals("stream-json", cmd[i + 1])
        end
      end
      assert.is_true(has_verbose)
      assert.is_true(has_format)
    end)

    it("should include tools when provided", function()
      local adapter = ClaudeAdapter:new(mock_config)
      local cmd = adapter:build_command("test", {
        tools = { "Read", "Write", "Edit" },
      })

      local has_tools = false
      for i, arg in ipairs(cmd) do
        if arg == "--tools" then
          has_tools = true
          assert.equals("Read,Write,Edit", cmd[i + 1])
        end
      end
      assert.is_true(has_tools)
    end)

    it("should include model when provided", function()
      local adapter = ClaudeAdapter:new(mock_config)
      local cmd = adapter:build_command("test", {
        model = "claude-3-opus-20240229",
      })

      local has_model = false
      for i, arg in ipairs(cmd) do
        if arg == "--model" then
          has_model = true
          assert.equals("claude-3-opus-20240229", cmd[i + 1])
        end
      end
      assert.is_true(has_model)
    end)

    it("should include context files", function()
      local adapter = ClaudeAdapter:new(mock_config)
      local cmd = adapter:build_command("test", {
        context = { "@file:test1.lua", "@file:test2.lua" },
      })

      local has_contexts = false
      for _, arg in ipairs(cmd) do
        if arg == "@file:test1.lua" or arg == "@file:test2.lua" then
          has_contexts = true
        end
      end
      assert.is_true(has_contexts)
    end)
  end)

  describe("execute", function()
    it("should call vim.fn.system with built command", function()
      local adapter = ClaudeAdapter:new(mock_config)
      local original_system = vim.fn.system
      local original_shell_error = vim.v.shell_error

      local cmd_called = nil
      vim.fn.system = function(cmd)
        cmd_called = cmd
        return "Test response"
      end
      vim.v = { shell_error = 0 }

      local result = adapter:execute("Hello", {})

      assert.is_not_nil(cmd_called)
      assert.equals("Test response", result.content)

      -- Restore
      vim.fn.system = original_system
      vim.v.shell_error = original_shell_error
    end)

    it("should handle error exit code", function()
      local adapter = ClaudeAdapter:new(mock_config)
      local original_system = vim.fn.system
      local original_shell_error = vim.v.shell_error

      vim.fn.system = function(cmd)
        return "Error message"
      end
      vim.v = { shell_error = 1 }

      local result = adapter:execute("Hello", {})

      assert.equals("", result.content)
      assert.equals("Error message", result.error)

      -- Restore
      vim.fn.system = original_system
      vim.v.shell_error = original_shell_error
    end)
  end)

  describe("supports", function()
    it("should support streaming", function()
      local adapter = ClaudeAdapter:new(mock_config)
      assert.is_true(adapter:supports("streaming"))
    end)

    it("should support tools", function()
      local adapter = ClaudeAdapter:new(mock_config)
      assert.is_true(adapter:supports("tools"))
    end)

    it("should support model_selection", function()
      local adapter = ClaudeAdapter:new(mock_config)
      assert.is_true(adapter:supports("model_selection"))
    end)

    it("should support context", function()
      local adapter = ClaudeAdapter:new(mock_config)
      assert.is_true(adapter:supports("context"))
    end)

    it("should not support unknown features", function()
      local adapter = ClaudeAdapter:new(mock_config)
      assert.is_false(adapter:supports("unknown_feature"))
    end)
  end)

  describe("stream", function()
    it("should call build_command with streaming option", function()
      local adapter = ClaudeAdapter:new(mock_config)
      local build_called = false
      local original_build = adapter.build_command

      adapter.build_command = function(self, prompt, opts)
        build_called = true
        assert.is_true(opts.streaming)
        return original_build(self, prompt, opts)
      end

      -- Mock vim.system to prevent actual execution
      local original_system = vim.system
      vim.system = function(cmd, opts, callback)
        callback({ code = 0 })
        return { kill = function() end }
      end

      adapter:stream("test", {}, function() end, function() end)

      assert.is_true(build_called)

      -- Restore
      vim.system = original_system
    end)
  end)
end)
