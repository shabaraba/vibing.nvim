-- Tests for vibing.infrastructure.rpc.handlers.execute module

describe("vibing.infrastructure.rpc.handlers.execute", function()
  local execute_handler

  before_each(function()
    -- Reload module before each test
    package.loaded["vibing.infrastructure.rpc.handlers.execute"] = nil
    execute_handler = require("vibing.infrastructure.rpc.handlers.execute")
  end)

  describe("execute", function()
    it("should execute command and return output", function()
      local result = execute_handler.execute({ command = "set wrap?" })
      assert.is_true(result.success)
      assert.is_not_nil(result.output)
    end)

    it("should return empty string for commands with no output", function()
      -- Commands like 'set number' don't produce output
      local result = execute_handler.execute({ command = "set number" })
      assert.is_true(result.success)
      assert.equals("", result.output)
    end)

    it("should handle commands that produce output", function()
      -- 'echo' commands produce output
      local result = execute_handler.execute({ command = "echo 'test output'" })
      assert.is_true(result.success)
      assert.is_string(result.output)
      assert.is_true(#result.output > 0)
    end)

    it("should raise error for invalid command", function()
      assert.has_error(function()
        execute_handler.execute({ command = "invalid_command_xyz_123" })
      end, "Command execution failed")
    end)

    it("should raise error for missing command parameter", function()
      assert.has_error(function()
        execute_handler.execute({})
      end, "Missing command parameter")
    end)

    it("should raise error when params is nil", function()
      assert.has_error(function()
        execute_handler.execute(nil)
      end, "Missing command parameter")
    end)

    it("should handle multi-line output", function()
      -- Create a command that produces multi-line output
      local result = execute_handler.execute({ command = "echo 'line1' | echo 'line2'" })
      assert.is_true(result.success)
      assert.is_string(result.output)
    end)

    it("should handle commands with special characters", function()
      local result = execute_handler.execute({ command = "echo 'hello world!'" })
      assert.is_true(result.success)
      assert.is_string(result.output)
    end)

    it("should handle empty echo command", function()
      local result = execute_handler.execute({ command = "echo ''" })
      assert.is_true(result.success)
      -- Output should be empty or contain just whitespace
      assert.is_string(result.output)
    end)
  end)

  describe("error cases", function()
    it("should provide meaningful error message on failure", function()
      local ok, err = pcall(function()
        execute_handler.execute({ command = "this_is_definitely_invalid" })
      end)
      assert.is_false(ok)
      assert.is_string(err)
      assert.is_true(err:match("Command execution failed") ~= nil)
    end)

    it("should handle commands that modify editor state", function()
      -- Commands like 'set' that change editor settings
      local result = execute_handler.execute({ command = "set wrap" })
      assert.is_true(result.success)

      -- Verify the setting was changed
      local verify = execute_handler.execute({ command = "set wrap?" })
      assert.is_true(verify.success)
      assert.is_true(verify.output:match("wrap") ~= nil)
    end)
  end)
end)
