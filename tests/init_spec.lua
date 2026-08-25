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
    package.loaded["vibing.application.chat"] = nil
    package.loaded["vibing.application.chat.commands"] = nil
    package.loaded["vibing.application.chat.custom_commands"] = nil
    package.loaded["vibing.application.completion"] = nil
    package.loaded["vibing.presentation.chat.controller"] = nil
    package.loaded["vibing.presentation.context.controller"] = nil
    package.loaded["vibing.core.utils.notify"] = nil
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

      -- Adapter creation is deferred via vim.schedule to keep it off the
      -- startup path; drain the scheduled callback before asserting.
      vim.wait(1000, function()
        return Vibing.adapter ~= nil
      end)
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
        -- events is a table like { "BufReadPost", "BufEnter", "BufWinEnter" }
        -- pattern is a table like { "*.md", "*.vibing" }
        if type(events) == "table" and type(opts.pattern) == "table" then
          local has_bufreadpost = false
          local has_md_pattern = false
          for _, ev in ipairs(events) do
            if ev == "BufReadPost" then
              has_bufreadpost = true
            end
          end
          for _, pat in ipairs(opts.pattern) do
            if pat == "*.md" then
              has_md_pattern = true
            end
          end
          if has_bufreadpost and has_md_pattern then
            autocmd_created = true
            autocmd_pattern = opts.pattern
          end
        end
        return 0
      end

      Vibing.setup()

      assert.is_true(autocmd_created)
      assert.is_true(vim.tbl_contains(autocmd_pattern, "*.md"))
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
        "VibingCancel",
        "VibingSummarize",
        "VibingChatFork",
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

    describe("VibingPendingResumes", function()
      local original_auto_resume

      before_each(function()
        original_auto_resume = package.loaded["vibing.application.chat.auto_resume"]
      end)

      after_each(function()
        package.loaded["vibing.application.chat.auto_resume"] = original_auto_resume
      end)

      it("renders a kind-absent entry as auto-resume", function()
        package.loaded["vibing.application.chat.auto_resume"] = {
          list = function()
            return {
              {
                chat_file_path = "/tmp/no-kind.md",
                resets_at = os.time() + 900,
                limit_type = "weekly",
                retry_count = 0,
                -- kind intentionally absent: must be read as auto-resume, not dropped/errored
              },
            }
          end,
          format_duration = function(seconds)
            return seconds .. "s"
          end,
        }

        local callback
        vim.api.nvim_create_user_command = function(name, cb)
          if name == "VibingPendingResumes" then
            callback = cb
          end
        end

        local info_message
        package.loaded["vibing.core.utils.notify"].info = function(msg)
          info_message = msg
        end

        Vibing.setup()
        callback()

        assert.is_not_nil(info_message)
        assert.matches("no%-kind%.md.*%[auto%-resume, weekly", info_message)
      end)

      it("renders a scheduled entry as scheduled, not auto-resume", function()
        package.loaded["vibing.application.chat.auto_resume"] = {
          list = function()
            return {
              {
                chat_file_path = "/tmp/scheduled.md",
                kind = "scheduled",
                resets_at = os.time() + 1800,
                retry_count = 0,
              },
            }
          end,
          format_duration = function(seconds)
            return seconds .. "s"
          end,
        }

        local callback
        vim.api.nvim_create_user_command = function(name, cb)
          if name == "VibingPendingResumes" then
            callback = cb
          end
        end

        local info_message
        package.loaded["vibing.core.utils.notify"].info = function(msg)
          info_message = msg
        end

        Vibing.setup()
        callback()

        assert.is_not_nil(info_message)
        assert.matches("scheduled%.md.*%[scheduled,", info_message)
      end)
    end)

    describe("VibingSchedule", function()
      local original_auto_resume, original_view, original_limit_state
      local scratch_bufnr, scratch_path
      local unwritable_bufnr, unwritable_dir, unwritable_path

      before_each(function()
        original_auto_resume = package.loaded["vibing.application.chat.auto_resume"]
        original_view = package.loaded["vibing.presentation.chat.view"]
        original_limit_state = package.loaded["vibing.infrastructure.storage.limit_state"]

        scratch_path = vim.fn.tempname() .. "-vibing-schedule-spec.md"
        scratch_bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(scratch_bufnr, scratch_path)

        -- A real (non-scratch) buffer named under a directory that does not exist, so `:write`
        -- deterministically fails (E212) and `vim.bo[bufnr].modified` stays true afterward. A
        -- scratch buffer (scratch=true) does not reproduce this: `:write` against one clears
        -- `modified` even when nothing was written, which would make the save-failure path
        -- untestable through it.
        unwritable_dir = vim.fn.tempname()
        unwritable_path = unwritable_dir .. "/does-not-exist/chat.md"
        unwritable_bufnr = vim.api.nvim_create_buf(false, false)
        vim.api.nvim_buf_set_name(unwritable_bufnr, unwritable_path)
        vim.api.nvim_buf_set_lines(unwritable_bufnr, 0, -1, false, { "## User <!-- unsent -->", "hello there" })
      end)

      after_each(function()
        package.loaded["vibing.application.chat.auto_resume"] = original_auto_resume
        package.loaded["vibing.presentation.chat.view"] = original_view
        package.loaded["vibing.infrastructure.storage.limit_state"] = original_limit_state
        pcall(vim.api.nvim_buf_delete, scratch_bufnr, { force = true })
        if scratch_path then
          vim.fn.delete(scratch_path)
        end
        pcall(vim.api.nvim_buf_delete, unwritable_bufnr, { force = true })
        -- unwritable_dir is never created on disk (that's the point: `:write` must fail because
        -- its "does-not-exist" child never exists), so there is nothing under it to delete here.
      end)

      --- @param bufnr number
      --- @param message string|nil
      --- @param frontmatter table|nil The chat's frontmatter; its `agent` decides which backend's
      ---   recorded usage limit these commands read and clear.
      local function stub_chat_buffer(bufnr, message, frontmatter)
        package.loaded["vibing.presentation.chat.view"] = {
          get_current = function()
            return {
              get_buffer = function()
                return bufnr
              end,
              extract_user_message = function()
                return message
              end,
              parse_frontmatter = function()
                return frontmatter or {}
              end,
            }
          end,
        }
      end

      it("passes quiet = true to AutoResume.schedule_request (no duplicate notification)", function()
        stub_chat_buffer(scratch_bufnr, "hello there")

        local captured_opts
        package.loaded["vibing.application.chat.auto_resume"] = {
          schedule_request = function(_, _, opts)
            captured_opts = opts
            return true, nil
          end,
          format_duration = function(seconds)
            return seconds .. "s"
          end,
        }

        local callback
        vim.api.nvim_create_user_command = function(name, cb)
          if name == "VibingSchedule" then
            callback = cb
          end
        end

        Vibing.setup()
        callback({ args = "30m" })

        assert.is_not_nil(captured_opts)
        assert.is_true(captured_opts.quiet)
      end)

      it("does not arm a schedule when the chat file cannot be saved", function()
        stub_chat_buffer(unwritable_bufnr, "hello there")

        local schedule_request_called = false
        package.loaded["vibing.application.chat.auto_resume"] = {
          schedule_request = function()
            schedule_request_called = true
            return true, nil
          end,
          format_duration = function(seconds)
            return seconds .. "s"
          end,
        }

        local callback
        vim.api.nvim_create_user_command = function(name, cb)
          if name == "VibingSchedule" then
            callback = cb
          end
        end

        local warn_message
        package.loaded["vibing.core.utils.notify"].warn = function(msg)
          warn_message = msg
        end

        Vibing.setup()
        local ok, err = pcall(callback, { args = "30m" })

        assert.is_true(ok, err)
        assert.is_false(
          schedule_request_called,
          "AutoResume.schedule_request must not be called when the save failed"
        )
        assert.is_not_nil(warn_message)
        assert.matches("[Cc]ould not save", warn_message)
        -- The failed `:write` left the buffer's own unsaved-changes flag set; a passing save
        -- would have cleared it. This is the same signal the command itself checks.
        assert.is_true(vim.bo[unwritable_bufnr].modified)
      end)

      it("computes fire_at as resets_at + grace_sec when scheduling from an active limit", function()
        stub_chat_buffer(scratch_bufnr, "hello there")

        local resets_at = os.time() + 1200
        package.loaded["vibing.infrastructure.storage.limit_state"] = {
          get_active = function()
            return { resets_at = resets_at, limit_type = "five_hour" }
          end,
        }

        local captured_fire_at
        package.loaded["vibing.application.chat.auto_resume"] = {
          schedule_request = function(_, fire_at)
            captured_fire_at = fire_at
            return true, nil
          end,
          format_duration = function(seconds)
            return seconds .. "s"
          end,
        }

        local callback
        vim.api.nvim_create_user_command = function(name, cb)
          if name == "VibingSchedule" then
            callback = cb
          end
        end

        Vibing.setup()
        callback({ args = "" })

        -- mock_config.get() (outer before_each) returns no `agent` field at all, exercising the
        -- `agent.auto_resume_on_limit and ... or 10` fallback down to the default grace of 10.
        assert.equals(resets_at + 10, captured_fire_at)
      end)

      it("computes fire_at using a configured grace_sec instead of the default", function()
        stub_chat_buffer(scratch_bufnr, "hello there")

        local original_config_get = mock_config.get
        local resets_at = os.time() + 1200
        mock_config.get = function()
          return {
            mcp = { enabled = false },
            agent = { auto_resume_on_limit = { grace_sec = 45 } },
          }
        end

        package.loaded["vibing.infrastructure.storage.limit_state"] = {
          get_active = function()
            return { resets_at = resets_at, limit_type = "five_hour" }
          end,
        }

        local captured_fire_at
        package.loaded["vibing.application.chat.auto_resume"] = {
          schedule_request = function(_, fire_at)
            captured_fire_at = fire_at
            return true, nil
          end,
          format_duration = function(seconds)
            return seconds .. "s"
          end,
        }

        local callback
        vim.api.nvim_create_user_command = function(name, cb)
          if name == "VibingSchedule" then
            callback = cb
          end
        end

        Vibing.setup()
        callback({ args = "" })

        mock_config.get = original_config_get
        assert.equals(resets_at + 45, captured_fire_at)
      end)

      it("warns instead of erroring when there is no argument and no active limit", function()
        stub_chat_buffer(scratch_bufnr, "hello there")

        package.loaded["vibing.infrastructure.storage.limit_state"] = {
          get_active = function()
            return nil
          end,
        }
        package.loaded["vibing.application.chat.auto_resume"] = {
          schedule_request = function()
            error("schedule_request must not be called when there is no active limit and no argument")
          end,
          format_duration = function(seconds)
            return seconds .. "s"
          end,
        }

        local callback
        vim.api.nvim_create_user_command = function(name, cb)
          if name == "VibingSchedule" then
            callback = cb
          end
        end

        local warn_message
        package.loaded["vibing.core.utils.notify"].warn = function(msg)
          warn_message = msg
        end

        Vibing.setup()
        local ok, err = pcall(callback, { args = "" })

        assert.is_true(ok, err)
        assert.is_not_nil(warn_message)
        assert.matches("No usage limit on record", warn_message)
      end)

      it("warns instead of erroring when there is no unsent message", function()
        stub_chat_buffer(scratch_bufnr, nil)

        local callback
        vim.api.nvim_create_user_command = function(name, cb)
          if name == "VibingSchedule" then
            callback = cb
          end
        end

        local warn_message
        package.loaded["vibing.core.utils.notify"].warn = function(msg)
          warn_message = msg
        end

        Vibing.setup()
        local ok, err = pcall(callback, { args = "30m" })

        assert.is_true(ok, err)
        assert.is_not_nil(warn_message)
        assert.matches("Write a message", warn_message)
      end)
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
      -- Adapter creation is deferred via vim.schedule (see setup); drain it.
      vim.wait(1000, function()
        return Vibing.adapter ~= nil
      end)
      assert.is_not_nil(Vibing.adapter)
      -- Should have at least 8 commands
      assert.is_true(commands_registered >= 8)
    end)
  end)
end)
