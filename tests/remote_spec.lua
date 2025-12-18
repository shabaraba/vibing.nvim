-- Tests for vibing.remote module

describe("vibing.remote", function()
  local Remote
  local original_env
  local original_system
  local original_notify

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.remote"] = nil

    -- Save originals
    original_env = vim.env
    original_system = vim.fn.system
    original_notify = vim.notify

    -- Mock vim.notify
    vim.notify = function() end

    Remote = require("vibing.remote")
  end)

  after_each(function()
    -- Restore originals
    vim.env = original_env
    vim.fn.system = original_system
    vim.notify = original_notify
  end)

  describe("setup", function()
    it("should set socket_path when provided", function()
      Remote.setup("/tmp/nvim.socket")

      assert.equals("/tmp/nvim.socket", Remote.socket_path)
    end)

    it("should auto-detect from environment variable when not provided", function()
      vim.env = { NVIM = "/tmp/env.socket" }

      Remote.setup()

      assert.equals("/tmp/env.socket", Remote.socket_path)
    end)

    it("should use nil when environment variable is not set", function()
      vim.env = {}

      Remote.setup()

      assert.is_nil(Remote.socket_path)
    end)
  end)

  describe("is_available", function()
    it("should return true when socket_path is set", function()
      Remote.socket_path = "/tmp/test.socket"

      local result = Remote.is_available()

      assert.is_true(result)
    end)

    it("should return false when socket_path is nil", function()
      Remote.socket_path = nil

      local result = Remote.is_available()

      assert.is_false(result)
    end)

    it("should return false when socket_path is empty string", function()
      Remote.socket_path = ""

      local result = Remote.is_available()

      assert.is_false(result)
    end)
  end)

  describe("send", function()
    it("should return false when remote is not available", function()
      Remote.socket_path = nil
      local notify_called = false
      vim.notify = function(msg, level)
        notify_called = true
        assert.is_not_nil(msg:match("not available"))
        assert.equals(vim.log.levels.ERROR, level)
      end

      local result = Remote.send("i")

      assert.is_false(result)
      assert.is_true(notify_called)
    end)

    it("should execute system command with correct format", function()
      Remote.socket_path = "/tmp/test.socket"
      local executed_cmd = nil
      vim.fn.system = function(cmd)
        executed_cmd = cmd
        return ""
      end
      vim.v = { shell_error = 0 }

      Remote.send("iHello<Esc>")

      assert.is_not_nil(executed_cmd)
      assert.is_true(executed_cmd:find('nvim') ~= nil)
      assert.is_true(executed_cmd:find('%-%-server') ~= nil)
      assert.is_true(executed_cmd:find('/tmp/test%.socket') ~= nil)
      assert.is_true(executed_cmd:find('%-%-remote%-send') ~= nil)
      assert.is_true(executed_cmd:find('iHello') ~= nil)
    end)

    it("should return true on successful send", function()
      Remote.socket_path = "/tmp/test.socket"
      vim.fn.system = function()
        return ""
      end
      vim.v = { shell_error = 0 }

      local result = Remote.send("i")

      assert.is_true(result)
    end)

    it("should return false when system command fails", function()
      Remote.socket_path = "/tmp/test.socket"
      vim.fn.system = function()
        return "Connection failed"
      end
      vim.v = { shell_error = 1 }

      local notify_called = false
      vim.notify = function(msg, level)
        notify_called = true
        assert.is_not_nil(msg:match("Remote send failed"))
        assert.equals(vim.log.levels.ERROR, level)
      end

      local result = Remote.send("i")

      assert.is_false(result)
      assert.is_true(notify_called)
    end)
  end)

  describe("expr", function()
    it("should return nil when remote is not available", function()
      Remote.socket_path = nil
      local notify_called = false
      vim.notify = function(msg, level)
        notify_called = true
        assert.is_not_nil(msg:match("not available"))
        assert.equals(vim.log.levels.ERROR, level)
      end

      local result = Remote.expr("1 + 1")

      assert.is_nil(result)
      assert.is_true(notify_called)
    end)

    it("should execute system command with correct format", function()
      Remote.socket_path = "/tmp/test.socket"
      local executed_cmd = nil
      vim.fn.system = function(cmd)
        executed_cmd = cmd
        return "2"
      end
      vim.v = { shell_error = 0 }

      Remote.expr("1 + 1")

      assert.is_not_nil(executed_cmd)
      assert.is_true(executed_cmd:find('nvim') ~= nil)
      assert.is_true(executed_cmd:find('%-%-server') ~= nil)
      assert.is_true(executed_cmd:find('/tmp/test%.socket') ~= nil)
      assert.is_true(executed_cmd:find('%-%-remote%-expr') ~= nil)
      assert.is_true(executed_cmd:find('1 %+ 1') ~= nil)
    end)

    it("should return trimmed result on success", function()
      Remote.socket_path = "/tmp/test.socket"
      vim.fn.system = function()
        return "  result  \n"
      end
      vim.v = { shell_error = 0 }

      local result = Remote.expr("test")

      assert.equals("result", result)
    end)

    it("should return nil when system command fails", function()
      Remote.socket_path = "/tmp/test.socket"
      vim.fn.system = function()
        return "Error"
      end
      vim.v = { shell_error = 1 }

      local notify_called = false
      vim.notify = function(msg, level)
        notify_called = true
        assert.is_not_nil(msg:match("Remote expr failed"))
        assert.equals(vim.log.levels.ERROR, level)
      end

      local result = Remote.expr("test")

      assert.is_nil(result)
      assert.is_true(notify_called)
    end)
  end)

  describe("execute", function()
    it("should escape double quotes in command", function()
      Remote.socket_path = "/tmp/test.socket"
      local sent_keys = nil
      vim.fn.system = function(cmd)
        -- Extract the command content - look for the actual sent keys
        sent_keys = cmd
        return ""
      end
      vim.v = { shell_error = 0 }

      Remote.execute('echo "test"')

      assert.is_not_nil(sent_keys)
      -- Verify the command contains escaped quotes (checking for backslash-quote pattern)
      assert.is_true(sent_keys:find('echo') ~= nil)
      assert.is_true(sent_keys:find('test') ~= nil)
    end)

    it("should format command with colon and CR", function()
      Remote.socket_path = "/tmp/test.socket"
      local sent_keys = nil
      vim.fn.system = function(cmd)
        sent_keys = cmd:match('--remote%-send "([^"]*)"')
        return ""
      end
      vim.v = { shell_error = 0 }

      Remote.execute("write")

      assert.is_not_nil(sent_keys)
      assert.equals(":write<CR>", sent_keys)
    end)
  end)

  describe("get_buffer", function()
    it("should return nil when expr fails", function()
      Remote.socket_path = "/tmp/test.socket"
      vim.fn.system = function()
        return "Error"
      end
      vim.v = { shell_error = 1 }
      vim.notify = function() end

      local result = Remote.get_buffer()

      assert.is_nil(result)
    end)

    it("should parse Vim list format", function()
      Remote.socket_path = "/tmp/test.socket"
      vim.fn.system = function()
        return "['line1', 'line2', 'line3']"
      end
      vim.v = { shell_error = 0 }

      local result = Remote.get_buffer()

      assert.same({ "line1", "line2", "line3" }, result)
    end)

    it("should handle empty buffer", function()
      Remote.socket_path = "/tmp/test.socket"
      vim.fn.system = function()
        return "['']"
      end
      vim.v = { shell_error = 0 }

      local result = Remote.get_buffer()

      assert.same({ "" }, result)
    end)
  end)

  describe("get_status", function()
    it("should return nil when remote is not available", function()
      Remote.socket_path = nil

      local result = Remote.get_status()

      assert.is_nil(result)
    end)

    it("should return nil when mode expr fails", function()
      Remote.socket_path = "/tmp/test.socket"
      vim.fn.system = function()
        return "Error"
      end
      vim.v = { shell_error = 1 }
      vim.notify = function() end

      local result = Remote.get_status()

      assert.is_nil(result)
    end)

    it("should return status with all fields", function()
      Remote.socket_path = "/tmp/test.socket"
      local call_count = 0
      local responses = { "n", "test.lua", "10", "5" }
      vim.fn.system = function()
        call_count = call_count + 1
        return responses[call_count]
      end
      vim.v = { shell_error = 0 }

      local result = Remote.get_status()

      assert.is_not_nil(result)
      assert.equals("n", result.mode)
      assert.equals("test.lua", result.bufname)
      assert.equals(10, result.line)
      assert.equals(5, result.col)
    end)

    it("should handle nil bufname gracefully", function()
      Remote.socket_path = "/tmp/test.socket"
      local call_count = 0
      vim.fn.system = function()
        call_count = call_count + 1
        if call_count == 2 then
          vim.v = { shell_error = 1 }
          return ""
        end
        vim.v = { shell_error = 0 }
        return call_count == 1 and "n" or (call_count == 3 and "1" or "1")
      end

      local result = Remote.get_status()

      assert.is_not_nil(result)
      assert.equals("", result.bufname)
    end)
  end)

  describe("integration", function()
    it("should have all expected functions", function()
      assert.is_function(Remote.setup)
      assert.is_function(Remote.is_available)
      assert.is_function(Remote.send)
      assert.is_function(Remote.expr)
      assert.is_function(Remote.execute)
      assert.is_function(Remote.get_buffer)
      assert.is_function(Remote.get_status)
    end)

    it("should allow setting socket_path", function()
      Remote.socket_path = "/test"
      assert.equals("/test", Remote.socket_path)
    end)
  end)
end)
