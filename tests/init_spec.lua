-- Tests for vibing.init module

describe("vibing.init", function()
  local Vibing
  local mock_config
  local mock_adapter
  local mock_chat
  local original_notify
  local original_create_user_command
  local original_create_autocmd

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.init"] = nil
    package.loaded["vibing.config"] = nil
    package.loaded["vibing.infrastructure.adapter.agent_sdk"] = nil
    package.loaded["vibing.application.chat"] = nil
    package.loaded["vibing.application.chat.commands"] = nil
    package.loaded["vibing.application.chat.custom_commands"] = nil
    package.loaded["vibing.application.completion"] = nil
    package.loaded["vibing.presentation.chat.controller"] = nil
    package.loaded["vibing.presentation.context.controller"] = nil
    package.loaded["vibing.core.utils.notify"] = nil
    package.loaded["vibing.mcp.setup"] = nil
    package.loaded["vibing.infrastructure.rpc.server"] = nil
    package.loaded["vibing.infrastructure.storage.frontmatter"] = nil

    -- Save originals
    original_notify = vim.notify
    original_create_user_command = vim.api.nvim_create_user_command
    original_create_autocmd = vim.api.nvim_create_autocmd

    -- Mock vim.notify
    vim.notify = function() end

    -- Mock notify module
    package.loaded["vibing.core.utils.notify"] = {
      error = function() end,
      warn = function() end,
      info = function() end,
    }

    -- Mock vim.api.nvim_create_user_command
    vim.api.nvim_create_user_command = function() end

    -- Mock vim.api.nvim_create_autocmd (with proper event table handling)
    vim.api.nvim_create_autocmd = function(events, opts)
      return 0
    end

    -- Mock config module
    mock_config = {
      setup = function() end,
      get = function()
        return {
          mcp = { enabled = false },
        }
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
    package.loaded["vibing.infrastructure.adapter.agent_sdk"] = mock_adapter

    -- Mock chat module
    mock_chat = {
      setup = function() end,
    }
    package.loaded["vibing.application.chat"] = mock_chat

    -- Mock chat commands
    package.loaded["vibing.application.chat.commands"] = {
      register_custom = function() end,
    }

    -- Mock custom commands
    package.loaded["vibing.application.chat.custom_commands"] = {
      get_all = function()
        return {}
      end,
    }

    -- Mock completion
    package.loaded["vibing.application.completion"] = {
      setup = function() end,
    }

    -- Mock presentation controllers
    package.loaded["vibing.presentation.chat.controller"] = {
      handle_open = function() end,
      handle_toggle = function() end,
      handle_summarize = function() end,
      handle_fork = function() end,
      handle_worktree = function() end,
      handle_set_file_title = function() end,
    }
    package.loaded["vibing.presentation.context.controller"] = {
      handle_add = function() end,
      handle_clear = function() end,
    }

    Vibing = require("vibing.init")
  end)

  after_each(function()
    -- Restore originals
    vim.notify = original_notify
    vim.api.nvim_create_user_command = original_create_user_command
    vim.api.nvim_create_autocmd = original_create_autocmd
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
      Vibing.setup()

      assert.is_not_nil(Vibing.adapter)
    end)

    it("should call chat setup", function()
      local chat_setup_called = false
      mock_chat.setup = function()
        chat_setup_called = true
      end

      Vibing.setup()

      assert.is_true(chat_setup_called)
    end)

    it("should register BufReadPost autocmd for .md files", function()
      local autocmd_created = false
      local autocmd_pattern = nil
      vim.api.nvim_create_autocmd = function(events, opts)
        -- events is a table like { "BufReadPost" }
        if type(events) == "table" then
          for _, ev in ipairs(events) do
            if ev == "BufReadPost" and opts.pattern == "*.md" then
              autocmd_created = true
              autocmd_pattern = opts.pattern
            end
          end
        end
        return 0
      end

      Vibing.setup()

      assert.is_true(autocmd_created)
      assert.equals("*.md", autocmd_pattern)
    end)

    it("should register commands", function()
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
        "VibingSummarize",
        "VibingChatFork",
        "VibingChatWorktree",
        "VibingSetFileTitle",
        "VibingReloadCommands",
      }

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
    it("VibingChat should call controller handle_open", function()
      local handle_open_called = false
      package.loaded["vibing.presentation.chat.controller"].handle_open = function()
        handle_open_called = true
      end

      local callback
      vim.api.nvim_create_user_command = function(name, cb)
        if name == "VibingChat" then
          callback = cb
        end
      end

      Vibing.setup()
      callback({ args = "" })

      assert.is_true(handle_open_called)
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
      mock_config.get = function()
        return {
          agent = {
            default_mode = "plan",
          },
          mcp = { enabled = false },
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
      -- Should have at least 8 commands
      assert.is_true(commands_registered >= 8)
    end)
  end)
end)
