local CliRuntime = require("vibing.infrastructure.adapter.modules.cli_runtime")
local helper = require("tests.helpers.adapter_stream")
local ActiveStreamRegistry = require("vibing.infrastructure.adapter.modules.active_stream_registry")

describe("cli_runtime", function()
  describe("new_handle_id", function()
    it("is hex, never scientific notation", function()
      -- LuaJIT renders large hrtime doubles as "2.64e+15", which pre-tool-use.sh's sanitized
      -- VIBING_HANDLE_ID then fails to match against the registry key.
      for _ = 1, 20 do
        local id = CliRuntime.new_handle_id()
        assert.is_truthy(id:match("^%x+_%x+$"), "not hex: " .. id)
        assert.is_nil(id:find("e+", 1, true))
      end
    end)

    it("does not repeat", function()
      local seen = {}
      for _ = 1, 200 do
        local id = CliRuntime.new_handle_id()
        assert.is_nil(seen[id], "duplicate handle id")
        seen[id] = true
      end
    end)
  end)

  describe("kill_tree", function()
    local original_system, spawned

    before_each(function()
      spawned = {}
      original_system = vim.system
      vim.system = function(cmd)
        table.insert(spawned, table.concat(cmd, " "))
        return { pid = 1, kill = function() end }
      end
    end)

    after_each(function()
      vim.system = original_system
    end)

    it("kills the children before the parent", function()
      local killed = nil
      CliRuntime.kill_tree({
        pid = 4242,
        kill = function(_, sig)
          killed = sig
        end,
      })

      assert.equals(1, #spawned)
      assert.is_truthy(spawned[1]:find("kill_descendants 4242", 1, true))
      assert.is_truthy(spawned[1]:find("pgrep -P", 1, true))
      assert.equals(9, killed)
    end)

    it("uses vim.system, not vim.fn.system, so the main loop is not blocked", function()
      -- cancel() can be reached from a vim.schedule callback; a blocking descendant walk there
      -- stalls Neovim for as long as it takes.
      local blocking = false
      local original_fn_system = vim.fn.system
      vim.fn.system = function(...)
        blocking = true
        return original_fn_system(...)
      end

      CliRuntime.kill_tree({ pid = 4242, kill = function() end })

      vim.fn.system = original_fn_system
      assert.is_false(blocking)
    end)

    it("does nothing without a usable pid", function()
      CliRuntime.kill_tree(nil)
      CliRuntime.kill_tree({})
      CliRuntime.kill_tree({ pid = 0 })
      CliRuntime.kill_tree({ pid = -1 })
      assert.equals(0, #spawned)
    end)

    it("survives a handle whose kill throws", function()
      assert.has_no.errors(function()
        CliRuntime.kill_tree({
          pid = 7,
          kill = function()
            error("already gone")
          end,
        })
      end)
    end)
  end)

  describe("report_build_failure", function()
    it("strips the Lua file:line prefix so the chat shows a message", function()
      local response
      CliRuntime.report_build_failure("h1", "/path/to/builder.lua:42: codex not found", function(r)
        response = r
      end)

      vim.wait(200, function()
        return response ~= nil
      end)
      assert.equals("codex not found", response.error)
      assert.equals("h1", response._handle_id)
      assert.equals("", response.content)
    end)

    it("handles a non-string error object", function()
      local response
      CliRuntime.report_build_failure("h1", { code = 1 }, function(r)
        response = r
      end)

      vim.wait(200, function()
        return response ~= nil
      end)
      assert.is_truthy(response.error)
    end)
  end)

  describe("spawn", function()
    local original_system

    before_each(function()
      original_system = vim.system
    end)

    after_each(function()
      vim.system = original_system
    end)

    --- @return boolean started, table response, table handles
    local function spawn_raising(cmd, err)
      vim.system = function()
        error(err)
      end

      local handles, response = {}, nil
      local started = CliRuntime.spawn(handles, "h1", cmd, {}, function() end, function(r)
        response = r
      end)
      vim.wait(200, function()
        return response ~= nil
      end)
      return started, response, handles
    end

    it("keeps the handle when the CLI starts", function()
      local handle = { pid = 4242 }
      vim.system = function()
        return handle
      end

      local handles = {}
      local reported = false
      local started = CliRuntime.spawn(handles, "h1", { "/bin/claude" }, {}, function() end, function()
        reported = true
      end)

      assert.is_true(started)
      assert.equals(handle, handles.h1.process)
      assert.equals(handle.pid, handles.h1.pid)
      assert.is_false(reported)
    end)

    it("names the binary and drops libuv's wording when it is gone", function()
      -- What the user gets when a CLI moves between the builder resolving it and the spawn (#593).
      -- "ENOENT ... (cmd)" is an error code, not something to act on.
      local raised = "vim/_system.lua:340: ENOENT: no such file or directory (cmd): '/old/bin/claude'"
      local started, response, handles = spawn_raising({ "/old/bin/claude", "-p" }, raised)

      assert.is_false(started)
      assert.is_nil(handles.h1, "a handle was recorded for a process that never started")
      assert.is_truthy(response.error:find("/old/bin/claude", 1, true))
      assert.is_truthy(response.error:find("could not be started", 1, true))
      assert.is_nil(response.error:find("ENOENT", 1, true))
      assert.equals("h1", response._handle_id)
    end)

    it("does not blame the CLI for a working directory that is gone", function()
      -- libuv raises ENOENT for a missing cwd as well, and the two are told apart only by the
      -- (cwd)/(cmd) marker. A chat's working_dir outlives `git worktree remove`, so this is the
      -- ordinary way to reach it -- and "reinstall the CLI" would be the wrong thing to do.
      local raised = "vim/_core/system:338: ENOENT: no such file or directory (cwd): '/gone/worktree'"
      local _, response = spawn_raising({ "/bin/claude" }, raised)

      assert.is_truthy(response.error:find("/gone/worktree", 1, true))
      assert.is_nil(response.error:find("Reinstall", 1, true), "blamed the CLI: " .. response.error)
    end)

    it("passes any other spawn failure through with its own text", function()
      local _, response = spawn_raising({ "/bin/claude" }, "EACCES: permission denied")

      assert.is_truthy(response.error:find("EACCES: permission denied", 1, true))
    end)
  end)
end)

-- The two behaviours below were not the same on every backend before the extraction: only grok
-- cancelled a timed-out execute(), and only claude left the child processes alive on cancel().
-- Running them over every adapter is what stops that drifting apart again.
for _, backend in ipairs(helper.adapters()) do
  describe("cli_runtime installed on " .. backend.name, function()
    local system, adapter

    before_each(function()
      system = helper.stub_system()
      adapter = backend.module:new({ agent = { default_model = "sonnet" } })
    end)

    after_each(function()
      system.restore()
    end)

    it("answers supports() from its own feature table", function()
      assert.is_boolean(adapter:supports("streaming"))
      assert.is_false(adapter:supports("a feature no backend has"))
    end)

    it("cancel kills the children that hold the stdout pipe open", function()
      local killed = false
      helper.run_stream(adapter)
      local handle = system.only_call().handle
      handle.kill = function()
        killed = true
      end

      local before = #system.calls
      adapter:cancel()

      local descendant_kill = nil
      for i = before + 1, #system.calls do
        local cmd = table.concat(system.calls[i].cmd, " ")
        if cmd:find("kill_descendants", 1, true) then
          descendant_kill = cmd
        end
      end

      assert.is_truthy(descendant_kill, "no descendant kill issued: the exit handler would never fire")
      assert.is_truthy(descendant_kill:find("kill_descendants " .. tostring(handle.pid), 1, true))
      assert.is_true(killed)
    end)

    it("cancel completes the stream even if the process never reports exit", function()
      local result = helper.run_stream(adapter)

      adapter:cancel(result.handle_id)
      vim.wait(200, function()
        return #result.done_responses > 0
      end)

      assert.equals(1, #result.done_responses)
      assert.is_true(result.done_responses[1]._cancelled)
      assert.equals("Cancelled", result.done_responses[1].error)
      assert.is_nil(ActiveStreamRegistry.get(result.handle_id))
    end)

    it("cancel forgets the handle so a later cancel is a no-op", function()
      helper.run_stream(adapter)
      adapter:cancel()
      assert.has_no.errors(function()
        adapter:cancel()
      end)
    end)

    it("execute cancels a run that never finishes rather than leaving it alive", function()
      -- The timeout is module-level state, so it is restored before the assertions rather than
      -- after: a failing assertion here would otherwise leave every later spec on a 50ms budget.
      local original_timeout = CliRuntime.INITIAL_RESPONSE_TIMEOUT_MS
      local original_cancel = adapter.cancel

      local cancelled_with = false
      adapter.cancel = function(self, handle_id)
        cancelled_with = handle_id
        return original_cancel(self, handle_id)
      end

      CliRuntime.INITIAL_RESPONSE_TIMEOUT_MS = 50
      -- stub_system never invokes on_exit, so on_done never fires: the timeout path.
      local ok, result = pcall(adapter.execute, adapter, "hi", {})
      CliRuntime.INITIAL_RESPONSE_TIMEOUT_MS = original_timeout
      adapter.cancel = original_cancel

      assert.is_true(ok, tostring(result))
      assert.equals("Execution timeout", result.error)
      assert.is_string(cancelled_with, "the timed-out handle was not cancelled")
    end)
  end)
end
