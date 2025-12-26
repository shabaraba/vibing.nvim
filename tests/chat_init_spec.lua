-- Tests for vibing.chat.init module

describe("vibing.chat.init", function()
  local ChatInit
  local Commands

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.chat.commands"] = nil
    package.loaded["vibing.chat.init"] = nil
    package.loaded["vibing.chat.handlers.context"] = nil
    package.loaded["vibing.chat.handlers.clear"] = nil
    package.loaded["vibing.chat.handlers.save"] = nil
    package.loaded["vibing.chat.handlers.summarize"] = nil
    package.loaded["vibing.chat.handlers.mode"] = nil
    package.loaded["vibing.chat.handlers.model"] = nil
    package.loaded["vibing.chat.handlers.help"] = nil
    package.loaded["vibing.chat.handlers.allow"] = nil
    package.loaded["vibing.chat.handlers.deny"] = nil
    package.loaded["vibing.chat.handlers.permission"] = nil
    package.loaded["vibing.chat.handlers.permissions"] = nil
    package.loaded["vibing.ui.permission_builder"] = nil
    package.loaded["vibing.constants.tools"] = nil

    Commands = require("vibing.chat.commands")
    ChatInit = require("vibing.chat.init")

    -- Reset commands registry
    Commands.commands = {}
  end)

  describe("setup", function()
    it("should register all built-in commands", function()
      ChatInit.setup()

      local expected_commands = { "context", "clear", "save", "summarize", "mode", "model", "help", "allow", "deny", "permission", "permissions", "perm" }

      for _, cmd_name in ipairs(expected_commands) do
        assert.is_not_nil(Commands.commands[cmd_name], "Command '" .. cmd_name .. "' should be registered")
      end
    end)

    it("should register context command with handler", function()
      ChatInit.setup()

      local cmd = Commands.commands["context"]
      assert.is_not_nil(cmd)
      assert.equals("context", cmd.name)
      assert.is_function(cmd.handler)
      assert.is_not_nil(cmd.description)
      assert.is_not_nil(cmd.description:match("file"))
    end)

    it("should register clear command with handler", function()
      ChatInit.setup()

      local cmd = Commands.commands["clear"]
      assert.is_not_nil(cmd)
      assert.equals("clear", cmd.name)
      assert.is_function(cmd.handler)
      assert.is_not_nil(cmd.description)
      assert.is_not_nil(cmd.description:match("[Cc]lear"))
    end)

    it("should register save command with handler", function()
      ChatInit.setup()

      local cmd = Commands.commands["save"]
      assert.is_not_nil(cmd)
      assert.equals("save", cmd.name)
      assert.is_function(cmd.handler)
      assert.is_not_nil(cmd.description)
      assert.is_not_nil(cmd.description:match("[Ss]ave"))
    end)

    it("should register summarize command with handler", function()
      ChatInit.setup()

      local cmd = Commands.commands["summarize"]
      assert.is_not_nil(cmd)
      assert.equals("summarize", cmd.name)
      assert.is_function(cmd.handler)
      assert.is_not_nil(cmd.description)
      assert.is_not_nil(cmd.description:match("[Ss]ummarize"))
    end)

    it("should register mode command with handler", function()
      ChatInit.setup()

      local cmd = Commands.commands["mode"]
      assert.is_not_nil(cmd)
      assert.equals("mode", cmd.name)
      assert.is_function(cmd.handler)
      assert.is_not_nil(cmd.description)
      assert.is_not_nil(cmd.description:match("mode"))
    end)

    it("should register model command with handler", function()
      ChatInit.setup()

      local cmd = Commands.commands["model"]
      assert.is_not_nil(cmd)
      assert.equals("model", cmd.name)
      assert.is_function(cmd.handler)
      assert.is_not_nil(cmd.description)
      assert.is_not_nil(cmd.description:match("model"))
    end)

    it("should have exactly 12 commands after setup", function()
      ChatInit.setup()

      local count = 0
      for _ in pairs(Commands.commands) do
        count = count + 1
      end

      assert.equals(13, count)
    end)

    it("should be idempotent (can be called multiple times)", function()
      ChatInit.setup()
      ChatInit.setup()

      local count = 0
      for _ in pairs(Commands.commands) do
        count = count + 1
      end

      assert.equals(13, count)
    end)

    it("should register commands with correct descriptions", function()
      ChatInit.setup()

      local cmd_descriptions = {
        context = "Add file to context: /context <file_path>",
        clear = "Clear context",
        save = "Save current chat",
        summarize = "Summarize conversation",
        mode = "Set execution mode: /mode <auto|plan|code>",
        model = "Set AI model: /model <opus|sonnet|haiku>",
      }

      for cmd_name, expected_desc in pairs(cmd_descriptions) do
        assert.equals(expected_desc, Commands.commands[cmd_name].description)
      end
    end)
  end)

  describe("integration", function()
    it("should enable command execution after setup", function()
      ChatInit.setup()

      -- Verify all commands can be detected and executed
      assert.is_true(Commands.is_command("/context test.lua"))
      assert.is_true(Commands.is_command("/clear"))
      assert.is_true(Commands.is_command("/save"))
      assert.is_true(Commands.is_command("/summarize"))
      assert.is_true(Commands.is_command("/mode auto"))
      assert.is_true(Commands.is_command("/model sonnet"))
      assert.is_true(Commands.is_command("/help"))
      assert.is_true(Commands.is_command("/allow Read"))
      assert.is_true(Commands.is_command("/deny Bash"))
      assert.is_true(Commands.is_command("/permission acceptEdits"))
    end)

    it("should provide command list after setup", function()
      ChatInit.setup()

      local list = Commands.list()

      assert.equals(12, #list)

      -- Verify all command names are in the list
      local command_names = {}
      for _, cmd in ipairs(list) do
        command_names[cmd.name] = true
      end

      assert.is_true(command_names["context"])
      assert.is_true(command_names["clear"])
      assert.is_true(command_names["save"])
      assert.is_true(command_names["summarize"])
      assert.is_true(command_names["mode"])
      assert.is_true(command_names["model"])
      assert.is_true(command_names["help"])
      assert.is_true(command_names["allow"])
      assert.is_true(command_names["deny"])
      assert.is_true(command_names["permission"])
    end)
  end)
end)
