-- Tests for vibing.chat.commands module

describe("vibing.chat.commands", function()
  local Commands

  before_each(function()
    -- Clear loaded modules to ensure clean state
    package.loaded["vibing.chat.commands"] = nil
    Commands = require("vibing.chat.commands")

    -- Reset commands registry
    Commands.commands = {}
  end)

  describe("register", function()
    it("should register a command", function()
      local test_command = {
        name = "test",
        handler = function() end,
        description = "Test command",
      }

      Commands.register(test_command)

      assert.is_not_nil(Commands.commands["test"])
      assert.equals("test", Commands.commands["test"].name)
    end)

    it("should overwrite existing command with same name", function()
      local command1 = {
        name = "test",
        handler = function() return 1 end,
        description = "First",
      }
      local command2 = {
        name = "test",
        handler = function() return 2 end,
        description = "Second",
      }

      Commands.register(command1)
      Commands.register(command2)

      assert.equals("Second", Commands.commands["test"].description)
    end)
  end)

  describe("is_command", function()
    it("should return true for valid slash command", function()
      assert.is_true(Commands.is_command("/test"))
      assert.is_true(Commands.is_command("/test arg1 arg2"))
      assert.is_true(Commands.is_command("/clear"))
    end)

    it("should return false for non-command messages", function()
      assert.is_false(Commands.is_command("test"))
      assert.is_false(Commands.is_command("Hello world"))
      assert.is_false(Commands.is_command(""))
    end)

    it("should return false for slash without word", function()
      assert.is_false(Commands.is_command("/"))
      assert.is_false(Commands.is_command("/ "))
    end)
  end)

  describe("parse", function()
    it("should parse command without arguments", function()
      local command_name, args = Commands.parse("/test")

      assert.equals("test", command_name)
      assert.same({}, args)
    end)

    it("should parse command with single argument", function()
      local command_name, args = Commands.parse("/context file.lua")

      assert.equals("context", command_name)
      assert.same({ "file.lua" }, args)
    end)

    it("should parse command with multiple arguments", function()
      local command_name, args = Commands.parse("/test arg1 arg2 arg3")

      assert.equals("test", command_name)
      assert.same({ "arg1", "arg2", "arg3" }, args)
    end)

    it("should handle extra whitespace", function()
      local command_name, args = Commands.parse("  /test   arg1   arg2  ")

      assert.equals("test", command_name)
      assert.same({ "arg1", "arg2" }, args)
    end)

    it("should return nil for non-command", function()
      local command_name, args = Commands.parse("not a command")

      assert.is_nil(command_name)
      assert.same({}, args)
    end)

    it("should return nil for just slash", function()
      local command_name, args = Commands.parse("/")

      assert.is_nil(command_name)
      assert.same({}, args)
    end)
  end)

  describe("execute", function()
    local mock_chat_buffer

    before_each(function()
      mock_chat_buffer = {}
    end)

    it("should return false for non-command message", function()
      local result = Commands.execute("Hello world", mock_chat_buffer)
      assert.is_false(result)
    end)

    it("should execute registered command handler", function()
      local handler_called = false
      local handler_args = nil

      Commands.register({
        name = "test",
        handler = function(args, chat_buffer)
          handler_called = true
          handler_args = args
          return true
        end,
        description = "Test",
      })

      local result = Commands.execute("/test arg1 arg2", mock_chat_buffer)

      assert.is_true(result)
      assert.is_true(handler_called)
      assert.same({ "arg1", "arg2" }, handler_args)
    end)

    it("should pass chat_buffer to handler", function()
      local received_buffer = nil

      Commands.register({
        name = "test",
        handler = function(args, chat_buffer)
          received_buffer = chat_buffer
          return true
        end,
        description = "Test",
      })

      Commands.execute("/test", mock_chat_buffer)

      assert.equals(mock_chat_buffer, received_buffer)
    end)

    it("should return false for unknown command (fallback to Agent SDK)", function()
      local result = Commands.execute("/unknown", mock_chat_buffer)
      assert.is_false(result)
    end)

    it("should handle handler errors gracefully", function()
      Commands.register({
        name = "test",
        handler = function()
          error("Handler error")
        end,
        description = "Test",
      })

      local result = Commands.execute("/test", mock_chat_buffer)
      assert.is_true(result)
    end)

    it("should not call handler when command parsing fails", function()
      local handler_called = false

      Commands.register({
        name = "test",
        handler = function()
          handler_called = true
        end,
        description = "Test",
      })

      Commands.execute("not a command", mock_chat_buffer)

      assert.is_false(handler_called)
    end)
  end)

  describe("list", function()
    it("should return empty list when no commands registered", function()
      local list = Commands.list()
      assert.same({}, list)
    end)

    it("should return all registered commands", function()
      Commands.register({
        name = "test1",
        handler = function() end,
        description = "Test 1",
      })
      Commands.register({
        name = "test2",
        handler = function() end,
        description = "Test 2",
      })

      local list = Commands.list()

      assert.equals(2, #list)
    end)

    it("should return commands sorted by name", function()
      Commands.register({
        name = "clear",
        handler = function() end,
        description = "Clear",
      })
      Commands.register({
        name = "save",
        handler = function() end,
        description = "Save",
      })
      Commands.register({
        name = "context",
        handler = function() end,
        description = "Context",
      })

      local list = Commands.list()

      assert.equals("clear", list[1].name)
      assert.equals("context", list[2].name)
      assert.equals("save", list[3].name)
    end)

    it("should include command properties", function()
      Commands.register({
        name = "test",
        handler = function() return true end,
        description = "Test command",
      })

      local list = Commands.list()

      assert.equals(1, #list)
      assert.equals("test", list[1].name)
      assert.equals("Test command", list[1].description)
      assert.is_function(list[1].handler)
    end)
  end)

  describe("integration", function()
    it("should support full command lifecycle", function()
      local execution_log = {}

      -- Register multiple commands
      Commands.register({
        name = "log",
        handler = function(args)
          table.insert(execution_log, { command = "log", args = args })
          return true
        end,
        description = "Log command",
      })

      Commands.register({
        name = "clear",
        handler = function()
          execution_log = {}
          return true
        end,
        description = "Clear log",
      })

      -- Execute commands
      Commands.execute("/log test1", {})
      Commands.execute("/log test2 arg", {})

      assert.equals(2, #execution_log)
      assert.equals("log", execution_log[1].command)
      assert.same({ "test1" }, execution_log[1].args)
      assert.same({ "test2", "arg" }, execution_log[2].args)

      -- Clear and verify
      Commands.execute("/clear", {})
      assert.equals(0, #execution_log)

      -- List commands
      local list = Commands.list()
      assert.equals(2, #list)
      assert.equals("clear", list[1].name)
      assert.equals("log", list[2].name)
    end)
  end)
end)
