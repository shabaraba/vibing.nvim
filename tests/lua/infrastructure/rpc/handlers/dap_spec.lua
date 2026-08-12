describe("rpc handler dap", function()
  local dap_handler

  --- Install a fake nvim-dap. The real one needs a running debug adapter, which a headless test
  --- has no way to provide — what these specs pin down is the shape of what we hand the agent and
  --- how we behave when there is nothing to inspect.
  ---@param session table|nil
  ---@param breakpoints table|nil captures set() calls
  local function install_dap(session, breakpoints)
    package.loaded["dap"] = {
      session = function()
        return session
      end,
    }
    package.loaded["dap.breakpoints"] = {
      set = function(opts, bufnr, line)
        if breakpoints then
          table.insert(breakpoints, { opts = opts, bufnr = bufnr, line = line })
        end
      end,
      set_breakpoints = function() end,
    }
  end

  --- A session that answers requests from a canned table.
  ---@param responses table<string, table>
  ---@param fields table|nil session field overrides. `false` clears a field — plain nil cannot,
  ---  since vim.tbl_extend drops nil values instead of applying them as removals.
  local function fake_session(responses, fields)
    local session = {
      stopped_thread_id = 1,
      current_frame = { id = 7, name = "main", line = 42, source = { path = "/tmp/app.py" } },
      config = { type = "python", name = "Launch file" },
    }
    for key, value in pairs(fields or {}) do
      session[key] = value ~= false and value or nil
    end

    session.request = function(_, command, _, callback)
      local response = responses[command]
      if response == nil then
        callback({ message = command .. " not supported" }, nil)
      else
        callback(nil, response)
      end
    end

    return session
  end

  before_each(function()
    package.loaded["vibing.infrastructure.rpc.handlers.dap"] = nil
    dap_handler = require("vibing.infrastructure.rpc.handlers.dap")
  end)

  after_each(function()
    package.loaded["dap"] = nil
    package.loaded["dap.breakpoints"] = nil
  end)

  describe("without nvim-dap installed", function()
    before_each(function()
      package.loaded["dap"] = nil
      -- Make `require("dap")` fail the way a missing plugin does.
      package.preload["dap"] = function()
        error("module 'dap' not found")
      end
    end)

    after_each(function()
      package.preload["dap"] = nil
    end)

    it("reports it as missing instead of erroring", function()
      local state = dap_handler.dap_get_state()
      assert.is_false(state.running)
      assert.is_truthy(state.reason:find("not installed", 1, true))
    end)

    it("says so from the tools that need a session too", function()
      local ok, err = pcall(dap_handler.dap_get_stack_trace, {})
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("not installed", 1, true))
    end)
  end)

  describe("dap_get_state", function()
    it("says there is nothing to inspect when no session is running", function()
      install_dap(nil)
      local state = dap_handler.dap_get_state()

      assert.is_false(state.running)
      assert.is_truthy(state.reason:find("no debug session", 1, true))
    end)

    it("describes where the debugger is stopped", function()
      install_dap(fake_session({}))
      local state = dap_handler.dap_get_state()

      assert.is_true(state.running)
      assert.equals("python", state.adapter)
      assert.equals(1, state.stopped_thread_id)
      assert.equals(42, state.current_frame.line)
      assert.equals("/tmp/app.py", state.current_frame.source)
    end)

    it("reports a running-but-not-stopped session without a frame", function()
      install_dap(fake_session({}, { stopped_thread_id = false, current_frame = false }))
      local state = dap_handler.dap_get_state()

      assert.is_true(state.running)
      assert.is_nil(state.current_frame)
    end)
  end)

  describe("dap_get_stack_trace", function()
    it("flattens the frames into what the agent needs to name a location", function()
      install_dap(fake_session({
        stackTrace = {
          stackFrames = {
            { id = 7, name = "divide", line = 12, column = 5, source = { path = "/tmp/app.py" } },
            { id = 8, name = "main", line = 40, source = { name = "<stdin>" } },
          },
        },
      }))

      local frames = dap_handler.dap_get_stack_trace({}).frames
      assert.equals(2, #frames)
      assert.equals("divide", frames[1].name)
      assert.equals("/tmp/app.py", frames[1].source)
      -- source.name is the fallback when the adapter has no path for the frame
      assert.equals("<stdin>", frames[2].source)
    end)

    it("refuses when nothing is stopped", function()
      install_dap(fake_session({}, { stopped_thread_id = false }))
      local ok, err = pcall(dap_handler.dap_get_stack_trace, {})

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("no stopped thread", 1, true))
    end)

    it("surfaces the adapter's own error", function()
      install_dap(fake_session({}))
      local ok, err = pcall(dap_handler.dap_get_stack_trace, {})

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("stackTrace not supported", 1, true))
    end)
  end)

  describe("dap_get_variables", function()
    it("groups the variables by scope", function()
      install_dap(fake_session({
        scopes = { scopes = { { name = "Locals", variablesReference = 3 } } },
        variables = {
          variables = {
            { name = "x", value = "-1", type = "int" },
            { name = "items", value = "[]", type = "list" },
          },
        },
      }))

      local scopes = dap_handler.dap_get_variables({}).scopes
      assert.equals(1, #scopes)
      assert.equals("Locals", scopes[1].name)
      assert.equals("x", scopes[1].variables[1].name)
      assert.equals("-1", scopes[1].variables[1].value)
    end)

    it("keeps a scope that cannot be expanded, rather than dropping it", function()
      -- variablesReference 0 means "no children"; the scope still tells the agent it exists.
      install_dap(fake_session({ scopes = { scopes = { { name = "Globals", variablesReference = 0 } } } }))

      local scopes = dap_handler.dap_get_variables({}).scopes
      assert.equals("Globals", scopes[1].name)
      assert.same({}, scopes[1].variables)
    end)

    it("spends one budget across every scope, not a fresh timeout each", function()
      -- vim.wait blocks the editor. A frame with several scopes must not multiply into tens of
      -- seconds of frozen Neovim just because the adapter is slow.
      local budgets = {}
      local session = fake_session({
        scopes = { scopes = { { name = "A", variablesReference = 1 }, { name = "B", variablesReference = 2 } } },
      })
      -- Never answer, so each request burns its whole budget.
      session.request = function(_, command, _, _)
        if command == "scopes" then
          return
        end
      end
      -- Record what each wait was given.
      local real_wait = vim.wait
      vim.wait = function(ms, ...)
        table.insert(budgets, ms)
        return real_wait(0, ...)
      end
      install_dap(session)

      pcall(dap_handler.dap_get_variables, {})
      vim.wait = real_wait

      assert.is_true(#budgets > 0)
      local total = 0
      for _, ms in ipairs(budgets) do
        total = total + ms
      end
      -- Every budget is carved out of the same 5s, so they cannot add up past it.
      assert.is_true(total <= 5000, "budgets summed to " .. total)
    end)

    it("refuses when the program is not stopped", function()
      install_dap(fake_session({}, { current_frame = false }))
      local ok, err = pcall(dap_handler.dap_get_variables, {})

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("no current frame", 1, true))
    end)
  end)

  describe("dap_set_breakpoint", function()
    local file

    before_each(function()
      file = vim.fn.tempname() .. ".py"
      vim.fn.writefile({ "def f():", "    return 1" }, file)
    end)

    after_each(function()
      vim.fn.delete(file)
    end)

    it("works without a session, since breakpoints outlive one", function()
      local set = {}
      install_dap(nil, set)

      local result = dap_handler.dap_set_breakpoint({ file = file, line = 2 })

      assert.is_true(result.success)
      assert.equals(2, set[1].line)
    end)

    it("passes a condition through", function()
      local set = {}
      install_dap(nil, set)

      dap_handler.dap_set_breakpoint({ file = file, line = 2, condition = "x < 0" })

      assert.equals("x < 0", set[1].opts.condition)
    end)

    it("does not display the file it attaches to", function()
      local set = {}
      install_dap(nil, set)
      local windows_before = #vim.api.nvim_list_wins()

      dap_handler.dap_set_breakpoint({ file = file, line = 1 })

      assert.equals(windows_before, #vim.api.nvim_list_wins())
      assert.is_true(vim.api.nvim_buf_is_loaded(set[1].bufnr))
    end)

    it("rejects a file that is not there", function()
      install_dap(nil)
      local ok, err = pcall(dap_handler.dap_set_breakpoint, { file = file .. ".missing", line = 1 })

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("does not exist", 1, true))
    end)

    it("rejects a line that cannot be one", function()
      install_dap(nil)
      assert.is_false(pcall(dap_handler.dap_set_breakpoint, { file = file, line = 0 }))
      assert.is_false(pcall(dap_handler.dap_set_breakpoint, { file = file, line = 1.5 }))
      assert.is_false(pcall(dap_handler.dap_set_breakpoint, { file = file }))
    end)
  end)

  describe("dap_evaluate", function()
    it("returns what the debuggee answered", function()
      install_dap(fake_session({ evaluate = { result = "-1", type = "int" } }))

      local result = dap_handler.dap_evaluate({ expression = "x" })
      assert.equals("-1", result.result)
      assert.equals("int", result.type)
    end)

    it("rejects an empty expression", function()
      install_dap(fake_session({}))
      assert.is_false(pcall(dap_handler.dap_evaluate, { expression = "" }))
      assert.is_false(pcall(dap_handler.dap_evaluate, {}))
    end)

    it("refuses without a session", function()
      install_dap(nil)
      local ok, err = pcall(dap_handler.dap_evaluate, { expression = "x" })

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("no debug session", 1, true))
    end)
  end)
end)
