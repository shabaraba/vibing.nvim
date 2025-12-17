-- Tests for vibing.actions.commands module

describe("vibing.actions.commands", function()
  local Commands

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.actions.commands"] = nil
    package.loaded["vibing.actions.chat"] = nil
    package.loaded["vibing.actions.inline"] = nil
    package.loaded["vibing.context"] = nil
    package.loaded["vibing"] = nil

    Commands = require("vibing.actions.commands")
  end)

  describe("chat commands", function()
    it("should call chat.open when chat() is called", function()
      local chat_module = {
        open = function() end,
      }
      local open_called = false
      chat_module.open = function()
        open_called = true
      end
      package.loaded["vibing.actions.chat"] = chat_module

      Commands.chat()

      assert.is_true(open_called)
    end)

    it("should call chat.close when chat_close() is called", function()
      local chat_module = {
        close = function() end,
      }
      local close_called = false
      chat_module.close = function()
        close_called = true
      end
      package.loaded["vibing.actions.chat"] = chat_module

      Commands.chat_close()

      assert.is_true(close_called)
    end)

    it("should call chat.toggle when chat_toggle() is called", function()
      local chat_module = {
        toggle = function() end,
      }
      local toggle_called = false
      chat_module.toggle = function()
        toggle_called = true
      end
      package.loaded["vibing.actions.chat"] = chat_module

      Commands.chat_toggle()

      assert.is_true(toggle_called)
    end)
  end)

  describe("inline action commands", function()
    it("should call inline.execute with 'fix' when fix() is called", function()
      local inline_module = {
        execute = function() end,
      }
      local execute_action = nil
      inline_module.execute = function(action)
        execute_action = action
      end
      package.loaded["vibing.actions.inline"] = inline_module

      Commands.fix()

      assert.equals("fix", execute_action)
    end)

    it("should call inline.execute with 'feat' when feat() is called", function()
      local inline_module = {
        execute = function() end,
      }
      local execute_action = nil
      inline_module.execute = function(action)
        execute_action = action
      end
      package.loaded["vibing.actions.inline"] = inline_module

      Commands.feat()

      assert.equals("feat", execute_action)
    end)

    it("should call inline.execute with 'explain' when explain() is called", function()
      local inline_module = {
        execute = function() end,
      }
      local execute_action = nil
      inline_module.execute = function(action)
        execute_action = action
      end
      package.loaded["vibing.actions.inline"] = inline_module

      Commands.explain()

      assert.equals("explain", execute_action)
    end)

    it("should call inline.execute with 'refactor' when refactor() is called", function()
      local inline_module = {
        execute = function() end,
      }
      local execute_action = nil
      inline_module.execute = function(action)
        execute_action = action
      end
      package.loaded["vibing.actions.inline"] = inline_module

      Commands.refactor()

      assert.equals("refactor", execute_action)
    end)

    it("should call inline.execute with 'test' when test() is called", function()
      local inline_module = {
        execute = function() end,
      }
      local execute_action = nil
      inline_module.execute = function(action)
        execute_action = action
      end
      package.loaded["vibing.actions.inline"] = inline_module

      Commands.test()

      assert.equals("test", execute_action)
    end)
  end)

  describe("custom prompt commands", function()
    it("should call inline.custom with use_output=true when ask() is called", function()
      local inline_module = {
        custom = function() end,
      }
      local custom_prompt = nil
      local custom_use_output = nil
      inline_module.custom = function(prompt, use_output)
        custom_prompt = prompt
        custom_use_output = use_output
      end
      package.loaded["vibing.actions.inline"] = inline_module

      Commands.ask("test prompt")

      assert.equals("test prompt", custom_prompt)
      assert.is_true(custom_use_output)
    end)

    it("should call inline.custom with use_output=false when do_action() is called", function()
      local inline_module = {
        custom = function() end,
      }
      local custom_prompt = nil
      local custom_use_output = nil
      inline_module.custom = function(prompt, use_output)
        custom_prompt = prompt
        custom_use_output = use_output
      end
      package.loaded["vibing.actions.inline"] = inline_module

      Commands.do_action("test action")

      assert.equals("test action", custom_prompt)
      assert.is_false(custom_use_output)
    end)
  end)

  describe("context commands", function()
    it("should call context.add when add_context() is called", function()
      local context_module = {
        add = function() end,
      }
      local add_path = nil
      context_module.add = function(path)
        add_path = path
      end
      package.loaded["vibing.context"] = context_module

      Commands.add_context("/path/to/file.lua")

      assert.equals("/path/to/file.lua", add_path)
    end)

    it("should call context.add with nil when add_context() is called without path", function()
      local context_module = {
        add = function() end,
      }
      local add_path = "not-nil"
      context_module.add = function(path)
        add_path = path
      end
      package.loaded["vibing.context"] = context_module

      Commands.add_context()

      assert.is_nil(add_path)
    end)

    it("should call context.clear when clear_context() is called", function()
      local context_module = {
        clear = function() end,
      }
      local clear_called = false
      context_module.clear = function()
        clear_called = true
      end
      package.loaded["vibing.context"] = context_module

      Commands.clear_context()

      assert.is_true(clear_called)
    end)
  end)

  describe("cancel command", function()
    it("should call adapter.cancel when adapter exists", function()
      local adapter_cancelled = false
      local mock_adapter = {
        cancel = function()
          adapter_cancelled = true
          return true
        end,
      }
      local vibing_module = {
        get_adapter = function()
          return mock_adapter
        end,
      }
      package.loaded["vibing"] = vibing_module

      Commands.cancel()

      assert.is_true(adapter_cancelled)
    end)

    it("should not error when adapter is nil", function()
      local vibing_module = {
        get_adapter = function()
          return nil
        end,
      }
      package.loaded["vibing"] = vibing_module

      -- Should not throw error
      Commands.cancel()
    end)

    it("should handle adapter.cancel returning false", function()
      local mock_adapter = {
        cancel = function()
          return false
        end,
      }
      local vibing_module = {
        get_adapter = function()
          return mock_adapter
        end,
      }
      package.loaded["vibing"] = vibing_module

      -- Should not throw error
      Commands.cancel()
    end)
  end)

  describe("integration", function()
    it("should have all expected command functions", function()
      local expected_commands = {
        "chat",
        "chat_close",
        "chat_toggle",
        "fix",
        "feat",
        "explain",
        "refactor",
        "test",
        "ask",
        "do_action",
        "add_context",
        "clear_context",
        "cancel",
      }

      for _, cmd_name in ipairs(expected_commands) do
        assert.is_function(Commands[cmd_name], "Command '" .. cmd_name .. "' should be a function")
      end
    end)
  end)
end)
