-- Tests for vibing.init module

describe("vibing.init", function()
  local Vibing
  local mock_config
  local mock_adapter
  local mock_chat
  local mock_remote
  local original_notify
  local original_create_user_command

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.init"] = nil
    package.loaded["vibing.config"] = nil
    package.loaded["vibing.adapters.agent_sdk"] = nil
    package.loaded["vibing.chat"] = nil
    package.loaded["vibing.remote"] = nil
    package.loaded["vibing.actions.chat"] = nil
    package.loaded["vibing.actions.inline"] = nil
    package.loaded["vibing.context"] = nil
    package.loaded["vibing.integrations.oil"] = nil
    package.loaded["vibing.context.migrator"] = nil

    -- Save originals
    original_notify = vim.notify
    original_create_user_command = vim.api.nvim_create_user_command

    -- Mock vim.notify
    vim.notify = function() end

    -- Mock vim.api.nvim_create_user_command
    vim.api.nvim_create_user_command = function() end

    -- Mock config module
    mock_config = {
      setup = function() end,
      get = function()
        return {
          adapter = "agent_sdk",
          remote = {
            auto_detect = false,
          },
        }
      end,
      defaults = {
        adapter = "agent_sdk",
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

    -- Mock remote module
    mock_remote = {
      setup = function() end,
      is_available = function()
        return true
      end,
      execute = function() end,
      get_status = function()
        return {
          mode = "n",
          bufname = "test.lua",
          line = 1,
          col = 1,
        }
      end,
    }
    package.loaded["vibing.remote"] = mock_remote

    Vibing = require("vibing.init")
  end)

  after_each(function()
    -- Restore originals
    vim.notify = original_notify
    vim.api.nvim_create_user_command = original_create_user_command
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

    it("should initialize remote control when auto_detect is enabled", function()
      package.loaded["vibing.adapters.agent_sdk"] = mock_adapter
      mock_config.get = function()
        return {
          adapter = "agent_sdk",
          remote = {
            auto_detect = true,
            socket_path = "/tmp/nvim.socket",
          },
        }
      end

      local remote_setup_called = false
      local remote_socket_path = nil
      mock_remote.setup = function(path)
        remote_setup_called = true
        remote_socket_path = path
      end

      Vibing.setup()

      assert.is_true(remote_setup_called)
      assert.equals("/tmp/nvim.socket", remote_socket_path)
    end)

    it("should not initialize remote when auto_detect is disabled", function()
      package.loaded["vibing.adapters.agent_sdk"] = mock_adapter
      local remote_setup_called = false
      mock_remote.setup = function()
        remote_setup_called = true
      end

      Vibing.setup()

      assert.is_false(remote_setup_called)
    end)

    it("should handle invalid adapter name", function()
      mock_config.get = function()
        return {
          adapter = "nonexistent",
        }
      end

      local notify_called = false
      vim.notify = function(msg, level)
        notify_called = true
        assert.is_not_nil(msg:match("not found"))
        assert.equals(vim.log.levels.ERROR, level)
      end

      Vibing.setup()

      assert.is_true(notify_called)
      assert.is_nil(Vibing.adapter)
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
        "VibingExplain",
        "VibingFix",
        "VibingFeature",
        "VibingRefactor",
        "VibingTest",
        "VibingCustom",
        "VibingCancel",
        "VibingOpenChat",
        "VibingRemote",
        "VibingRemoteStatus",
        "VibingSendToChat",
        "VibingReloadCommands",
        "VibingMigrate",
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
      callback()

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

    it("VibingRemote should execute remote command", function()
      local execute_called = false
      local execute_cmd = nil
      mock_remote.execute = function(cmd)
        execute_called = true
        execute_cmd = cmd
      end

      local callback
      vim.api.nvim_create_user_command = function(name, cb)
        if name == "VibingRemote" then
          callback = cb
        end
      end

      Vibing.setup()
      callback({ args = "write" })

      assert.is_true(execute_called)
      assert.equals("write", execute_cmd)
    end)

    it("VibingRemoteStatus should get and print status", function()
      local callback
      vim.api.nvim_create_user_command = function(name, cb)
        if name == "VibingRemoteStatus" then
          callback = cb
        end
      end

      Vibing.setup()
      -- Should not error
      callback()
    end)

    it("VibingMigrate should handle empty args (current buffer)", function()
      local original_cmd = vim.cmd
      vim.cmd = function() end

      local migrator_called = false
      local mock_migrator = {
        migrate_current_buffer = function()
          migrator_called = true
          return true
        end,
      }
      package.loaded["vibing.context.migrator"] = mock_migrator

      mock_chat.chat_buffer = {
        file_path = "/tmp/test.md",
      }

      local callback
      vim.api.nvim_create_user_command = function(name, cb)
        if name == "VibingMigrate" then
          callback = cb
        end
      end

      Vibing.setup()
      callback({ args = "" })

      assert.is_true(migrator_called)

      -- Restore
      vim.cmd = original_cmd
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
        return { adapter = "test" }
      end

      Vibing.setup()
      local config = Vibing.get_config()

      assert.equals("test", config.adapter)
    end)

    it("should return defaults when no config", function()
      Vibing.config = nil

      local config = Vibing.get_config()

      assert.equals("agent_sdk", config.adapter)
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

      Vibing.setup({ adapter = "agent_sdk" })

      assert.is_true(config_setup_called)
      assert.is_true(chat_setup_called)
      assert.is_not_nil(Vibing.adapter)
      assert.equals(19, commands_registered)
    end)
  end)
end)
