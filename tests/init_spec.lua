-- Tests for vibing.init module

describe("vibing.init", function()
  local Vibing
  local mock_config
  local mock_adapter
  local mock_chat
  local original_notify
  local original_create_user_command
  local original_filetype_add

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.init"] = nil
    package.loaded["vibing.config"] = nil
    package.loaded["vibing.adapters.agent_sdk"] = nil
    package.loaded["vibing.chat"] = nil
    package.loaded["vibing.actions.chat"] = nil
    package.loaded["vibing.actions.inline"] = nil
    package.loaded["vibing.context"] = nil
    package.loaded["vibing.integrations.oil"] = nil
    package.loaded["vibing.utils.notify"] = nil

    -- Save originals
    original_notify = vim.notify
    original_create_user_command = vim.api.nvim_create_user_command
    original_filetype_add = vim.filetype.add

    -- Mock vim.notify
    vim.notify = function() end

    -- Mock notify module
    package.loaded["vibing.utils.notify"] = {
      error = function() end,
      warn = function() end,
      info = function() end,
    }

    -- Mock vim.api.nvim_create_user_command
    vim.api.nvim_create_user_command = function() end

    -- Mock vim.filetype.add
    vim.filetype.add = function() end

    -- Mock config module
    mock_config = {
      setup = function() end,
      get = function()
        return {}
      end,
      defaults = {
        agent = {
          default_mode = "code",
          default_model = "sonnet",
        },
      },
    }
    package.loaded["vibing.config"] = mock_config

    -- Mock adapter
    mock_adapter = {
      new = function(self, config)
        return {
          cancel = function() end,
        }
      end,
    }

    -- Mock chat module
    mock_chat = {
      setup = function() end,
      open = function() end,
      open_file = function() end,
      chat_buffer = nil,
    }
    package.loaded["vibing.chat"] = mock_chat
    package.loaded["vibing.actions.chat"] = mock_chat

    Vibing = require("vibing.init")
  end)

  after_each(function()
    -- Restore originals
    vim.notify = original_notify
    vim.api.nvim_create_user_command = original_create_user_command
    vim.filetype.add = original_filetype_add
  end)

  describe("setup", function()
    it("should call config setup", function()
      local setup_called = false
      mock_config.setup = function()
        setup_called = true
      end

      Vibing.setup()

      assert.is_true(setup_called)
    end)

    it("should initialize adapter", function()
      package.loaded["vibing.adapters.agent_sdk"] = mock_adapter

      Vibing.setup()

      assert.is_not_nil(Vibing.adapter)
    end)

    it("should call chat setup", function()
      package.loaded["vibing.adapters.agent_sdk"] = mock_adapter
      local chat_setup_called = false
      mock_chat.setup = function()
        chat_setup_called = true
      end

      Vibing.setup()

      assert.is_true(chat_setup_called)
    end)

    it("should register .vibing filetype", function()
      package.loaded["vibing.adapters.agent_sdk"] = mock_adapter
      local filetype_add_called = false
      local filetype_config = nil
      vim.filetype.add = function(config)
        filetype_add_called = true
        filetype_config = config
      end

      Vibing.setup()

      assert.is_true(filetype_add_called)
      assert.is_not_nil(filetype_config)
      assert.is_not_nil(filetype_config.extension)
      assert.equals("vibing", filetype_config.extension.vibing)
    end)


    it("should register commands", function()
      package.loaded["vibing.adapters.agent_sdk"] = mock_adapter
      local registered_commands = {}
      vim.api.nvim_create_user_command = function(name, callback, opts)
        table.insert(registered_commands, name)
      end

      Vibing.setup()

      -- Verify all expected commands are registered
      local expected = {
        "VibingChat",
        "VibingToggleChat",
        "VibingSlashCommands",
        "VibingContext",
        "VibingClearContext",
        "VibingInline",
        "VibingCancel",
        "VibingReloadCommands",
      }

      assert.equals(#expected, #registered_commands)
      for _, cmd in ipairs(expected) do
        local found = false
        for _, reg_cmd in ipairs(registered_commands) do
          if reg_cmd == cmd then
            found = true
            break
          end
        end
        assert.is_true(found, "Command '" .. cmd .. "' should be registered")
      end
    end)
  end)

  describe("command callbacks", function()
    before_each(function()
      package.loaded["vibing.adapters.agent_sdk"] = mock_adapter
    end)

    it("VibingChat should call chat.open", function()
      local chat_open_called = false
      mock_chat.open = function()
        chat_open_called = true
      end

      local callback
      vim.api.nvim_create_user_command = function(name, cb)
        if name == "VibingChat" then
          callback = cb
        end
      end

      Vibing.setup()
      callback({ args = "" })

      assert.is_true(chat_open_called)
    end)

    it("VibingCancel should call adapter cancel", function()
      local callback
      vim.api.nvim_create_user_command = function(name, cb)
        if name == "VibingCancel" then
          callback = cb
        end
      end

      Vibing.setup()

      local cancel_called = false
      Vibing.adapter = {
        cancel = function()
          cancel_called = true
        end,
      }

      callback()

      assert.is_true(cancel_called)
    end)
  end)

  describe("get_adapter", function()
    it("should return current adapter", function()
      Vibing.adapter = { test = "adapter" }

      local adapter = Vibing.get_adapter()

      assert.same({ test = "adapter" }, adapter)
    end)

    it("should return nil when no adapter", function()
      Vibing.adapter = nil

      local adapter = Vibing.get_adapter()

      assert.is_nil(adapter)
    end)
  end)

  describe("get_config", function()
    it("should return current config", function()
      package.loaded["vibing.adapters.agent_sdk"] = mock_adapter
      mock_config.get = function()
        return {
          agent = {
            default_mode = "plan"
          }
        }
      end

      Vibing.setup()
      local config = Vibing.get_config()

      assert.equals("plan", config.agent.default_mode)
    end)

    it("should return defaults when no config", function()
      Vibing.config = nil

      local config = Vibing.get_config()

      assert.equals("code", config.agent.default_mode)
    end)
  end)

  describe("integration", function()
    it("should have all expected functions", function()
      assert.is_function(Vibing.setup)
      assert.is_function(Vibing.get_adapter)
      assert.is_function(Vibing.get_config)
      assert.is_function(Vibing._register_commands)
    end)

    it("should support full initialization workflow", function()
      package.loaded["vibing.adapters.agent_sdk"] = mock_adapter
      local config_setup_called = false
      local chat_setup_called = false
      local commands_registered = 0

      mock_config.setup = function()
        config_setup_called = true
      end
      mock_chat.setup = function()
        chat_setup_called = true
      end
      vim.api.nvim_create_user_command = function()
        commands_registered = commands_registered + 1
      end

      Vibing.setup({})

      assert.is_true(config_setup_called)
      assert.is_true(chat_setup_called)
      assert.is_not_nil(Vibing.adapter)
      assert.equals(8, commands_registered)
    end)
  end)
end)
