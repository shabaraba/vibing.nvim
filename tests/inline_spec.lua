-- Tests for vibing.actions.inline module

describe("vibing.actions.inline", function()
  local InlineActions
  local mock_vibing
  local mock_config
  local mock_adapter
  local mock_context

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.actions.inline"] = nil
    package.loaded["vibing"] = nil
    package.loaded["vibing.context"] = nil
    package.loaded["vibing.ui.output_buffer"] = nil
    package.loaded["vibing.ui.inline_progress"] = nil
    package.loaded["vibing.utils.buffer_reload"] = nil

    -- Setup mock config
    mock_config = {
      inline = {
        default_action = "fix",
      },
    }

    -- Mock adapter
    mock_adapter = {
      supports = function(feature)
        if feature == "streaming" then return true end
        if feature == "tools" then return true end
        return false
      end,
      stream = function(prompt, opts, on_chunk, on_done)
        vim.schedule(function()
          on_chunk("Test response")
          on_done({ content = "Test response" })
        end)
      end,
      execute = function(prompt, opts)
        return { content = "Test response" }
      end,
    }

    -- Mock vibing module
    mock_vibing = {
      get_config = function()
        return mock_config
      end,
      get_adapter = function()
        return mock_adapter
      end,
    }
    package.loaded["vibing"] = mock_vibing

    -- Mock context module
    mock_context = {
      get_selection = function()
        return "@file:test.lua:L1-L5"
      end,
    }
    package.loaded["vibing.context"] = mock_context

    -- Mock OutputBuffer
    package.loaded["vibing.ui.output_buffer"] = {
      new = function()
        return {
          open = function() end,
          append_chunk = function() end,
          set_content = function() end,
          show_error = function() end,
        }
      end,
    }

    -- Mock InlineProgress
    local MockInlineProgress = {}
    MockInlineProgress.__index = MockInlineProgress
    function MockInlineProgress:new()
      return setmetatable({ _modified_files = {} }, MockInlineProgress)
    end
    function MockInlineProgress:show() end
    function MockInlineProgress:update_status() end
    function MockInlineProgress:update_tool() end
    function MockInlineProgress:add_modified_file(path)
      table.insert(self._modified_files, path)
    end
    function MockInlineProgress:get_modified_files()
      return self._modified_files
    end
    function MockInlineProgress:close() end
    package.loaded["vibing.ui.inline_progress"] = MockInlineProgress

    -- Mock BufferReload
    package.loaded["vibing.utils.buffer_reload"] = {
      reload_files = function() end,
    }

    InlineActions = require("vibing.actions.inline")
  end)

  describe("actions table", function()
    it("should define fix action", function()
      assert.is_not_nil(InlineActions.actions.fix)
      assert.equals("Fix the following code issues:", InlineActions.actions.fix.prompt)
      assert.is_false(InlineActions.actions.fix.use_output_buffer)
    end)

    it("should define feat action", function()
      assert.is_not_nil(InlineActions.actions.feat)
      assert.equals("Implement the following feature by writing actual code. You MUST use Edit or Write tools to modify or create files. Do not just explain or provide suggestions - write the implementation directly into the files:", InlineActions.actions.feat.prompt)
      assert.is_false(InlineActions.actions.feat.use_output_buffer)
    end)

    it("should define explain action", function()
      assert.is_not_nil(InlineActions.actions.explain)
      assert.equals("Explain the following code:", InlineActions.actions.explain.prompt)
      assert.is_true(InlineActions.actions.explain.use_output_buffer)
    end)

    it("should define refactor action", function()
      assert.is_not_nil(InlineActions.actions.refactor)
      assert.is_false(InlineActions.actions.refactor.use_output_buffer)
    end)

    it("should define test action", function()
      assert.is_not_nil(InlineActions.actions.test)
      assert.is_false(InlineActions.actions.test.use_output_buffer)
    end)
  end)

  describe("execute", function()
    it("should handle no adapter gracefully", function()
      mock_vibing.get_adapter = function()
        return nil
      end

      -- Should not error, just notify
      InlineActions.execute("fix")
    end)

    it("should handle no selection gracefully", function()
      mock_context.get_selection = function()
        return nil
      end

      -- Should not error, just notify
      InlineActions.execute("fix")
    end)

    it("should call _execute_with_output for explain action", function()
      local output_called = false
      InlineActions._execute_with_output = function(adapter, prompt, opts, title)
        output_called = true
        assert.is_not_nil(prompt:match("Explain the following"))
      end

      InlineActions.execute("explain")
      assert.is_true(output_called)
    end)

    it("should call _execute_direct for fix action", function()
      local direct_called = false
      InlineActions._execute_direct = function(adapter, prompt, opts)
        direct_called = true
        assert.is_not_nil(prompt:match("Fix the following"))
      end

      InlineActions.execute("fix")
      assert.is_true(direct_called)
    end)

    it("should include selection context in prompt", function()
      local prompt_received = nil
      InlineActions._execute_direct = function(adapter, prompt, opts)
        prompt_received = prompt
      end

      InlineActions.execute("fix")
      assert.is_not_nil(prompt_received)
      assert.is_not_nil(prompt_received:match("@file:test.lua:L1%-L5"))
    end)

    it("should call custom for non-predefined action", function()
      local custom_called = false
      local original_custom = InlineActions.custom
      InlineActions.custom = function(prompt, use_output)
        custom_called = true
        assert.equals("custom instruction", prompt)
        assert.is_false(use_output)
      end

      InlineActions.execute("custom instruction")
      assert.is_true(custom_called)

      -- Restore
      InlineActions.custom = original_custom
    end)
  end)

  describe("custom", function()
    it("should handle no adapter gracefully", function()
      mock_vibing.get_adapter = function()
        return nil
      end

      -- Should not error, just notify
      InlineActions.custom("do something", false)
    end)

    it("should handle no selection gracefully", function()
      mock_context.get_selection = function()
        return nil
      end

      -- Should not error, just notify
      InlineActions.custom("do something", false)
    end)

    it("should call _execute_with_output when use_output is true", function()
      local output_called = false
      local original_func = InlineActions._execute_with_output
      InlineActions._execute_with_output = function(adapter, prompt, opts, title)
        output_called = true
        assert.equals("Result", title)
        assert.is_not_nil(prompt:match("custom task"))
      end

      InlineActions.custom("custom task", true)
      assert.is_true(output_called)

      -- Restore
      InlineActions._execute_with_output = original_func
    end)

    it("should call _execute_direct when use_output is false", function()
      local direct_called = false
      local original_func = InlineActions._execute_direct
      InlineActions._execute_direct = function(adapter, prompt, opts)
        direct_called = true
        assert.is_not_nil(prompt:match("fix this"))
      end

      InlineActions.custom("fix this", false)
      assert.is_true(direct_called)

      -- Restore
      InlineActions._execute_direct = original_func
    end)

    it("should combine prompt with selection context", function()
      local prompt_received = nil
      InlineActions._execute_direct = function(adapter, prompt, opts)
        prompt_received = prompt
      end

      InlineActions.custom("custom task", false)
      assert.is_not_nil(prompt_received)
      assert.is_not_nil(prompt_received:match("custom task"))
      assert.is_not_nil(prompt_received:match("@file:test.lua:L1%-L5"))
    end)
  end)

  -- Note: _execute_with_output and _execute_direct are tested indirectly
  -- through execute() and custom() tests above, which provide better
  -- integration testing without complex async mocking

  describe("_execute_direct", function()
    it("should handle non-streaming adapter", function()
      local execute_called = false
      mock_adapter.supports = function() return false end
      mock_adapter.execute = function(prompt, opts)
        execute_called = true
        return { content = "Done" }
      end

      InlineActions._execute_direct(mock_adapter, "test prompt", {})
      assert.is_true(execute_called)
    end)

    it("should notify on error", function()
      mock_adapter.supports = function() return false end
      mock_adapter.execute = function()
        return { error = "test error" }
      end

      -- Should not crash, just notify
      InlineActions._execute_direct(mock_adapter, "test", {})
    end)
  end)
end)
