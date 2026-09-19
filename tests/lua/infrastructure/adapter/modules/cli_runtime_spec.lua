local CliRuntime = require("vibing.infrastructure.adapter.modules.cli_runtime")
local helper = require("tests.helpers.adapter_stream")
local ActiveStreamRegistry = require("vibing.infrastructure.adapter.modules.active_stream_registry")

-- Deliberately distinct, so a site that uses one where it means the other misses instead of
-- working by coincidence. The id alphabet itself is tests/lua/core/utils/identity_spec.lua.
local IDS = { turn_id = "t1", process_id = "p1" }

describe("cli_runtime", function()
  describe("kill_tree", function()
    local original_system, spawned, exit_callbacks

    before_each(function()
      spawned = {}
      exit_callbacks = {}
      original_system = vim.system
      vim.system = function(cmd, _, on_exit)
        table.insert(spawned, table.concat(cmd, " "))
        table.insert(exit_callbacks, on_exit)
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
      assert.is_truthy(spawned[1]:find("kill -9 4242", 1, true))
      assert.is_true(spawned[1]:find("kill_descendants 4242", 1, true) < spawned[1]:find("kill -9 4242", 1, true))
      assert.is_nil(killed)

      exit_callbacks[1]({ code = 0 })
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
        exit_callbacks[1]({ code = 0 })
      end)
    end)
  end)

  describe("report_build_failure", function()
    it("strips the Lua file:line prefix so the chat shows a message", function()
      local response
      CliRuntime.report_build_failure(IDS, "/path/to/builder.lua:42: codex not found", function(r)
        response = r
      end)

      vim.wait(200, function()
        return response ~= nil
      end)
      assert.equals("codex not found", response.error)
      assert.equals("", response.content)
      -- Both ids, even though no process was ever started: the chat buffer's staleness check reads
      -- the turn and the session read-back reads the process, so a response missing either one is
      -- indistinguishable from someone else's.
      assert.equals("t1", response._handle_id)
      assert.equals("p1", response._process_id)
    end)

    it("handles a non-string error object", function()
      local response
      CliRuntime.report_build_failure(IDS, { code = 1 }, function(r)
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

    --- @return boolean started, table response, table processes
    local function spawn_raising(cmd, err)
      vim.system = function()
        error(err)
      end

      local processes, response = {}, nil
      local started = CliRuntime.spawn(processes, IDS, cmd, {}, function() end, function(r)
        response = r
      end)
      vim.wait(200, function()
        return response ~= nil
      end)
      return started, response, processes
    end

    it("keys the process table by the process id, not the turn", function()
      local handle = { pid = 4242 }
      vim.system = function()
        return handle
      end

      local processes = {}
      local reported = false
      local started = CliRuntime.spawn(processes, IDS, { "/bin/claude" }, {}, function() end, function()
        reported = true
      end)

      assert.is_true(started)
      assert.equals(handle, processes.p1.process)
      assert.equals(handle.pid, processes.p1.pid)
      assert.is_nil(processes.t1, "the process was filed under the turn id")
      assert.is_false(reported)
    end)

    it("names the binary and drops libuv's wording when it is gone", function()
      -- What the user gets when a CLI moves between the builder resolving it and the spawn (#593).
      -- "ENOENT ... (cmd)" is an error code, not something to act on.
      local raised = "vim/_system.lua:340: ENOENT: no such file or directory (cmd): '/old/bin/claude'"
      local started, response, processes = spawn_raising({ "/old/bin/claude", "-p" }, raised)

      assert.is_false(started)
      assert.is_nil(processes.p1, "a handle was recorded for a process that never started")
      assert.is_truthy(response.error:find("/old/bin/claude", 1, true))
      assert.is_truthy(response.error:find("could not be started", 1, true))
      assert.is_nil(response.error:find("ENOENT", 1, true))
      assert.equals("t1", response._handle_id)
      assert.equals("p1", response._process_id)
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
      local descendant_kill_on_exit = nil
      for i = before + 1, #system.calls do
        local cmd = table.concat(system.calls[i].cmd, " ")
        if cmd:find("kill_descendants", 1, true) then
          descendant_kill = cmd
          descendant_kill_on_exit = system.calls[i].on_exit
        end
      end

      assert.is_truthy(descendant_kill, "no descendant kill issued: the exit handler would never fire")
      assert.is_truthy(descendant_kill:find("kill_descendants " .. tostring(handle.pid), 1, true))
      assert.is_false(killed)
      descendant_kill_on_exit({ code = 0 })
      assert.is_true(killed)
    end)

    it("cancel completes the stream even if the process never reports exit", function()
      local result = helper.run_stream(adapter)

      adapter:cancel(result.process_id)
      vim.wait(200, function()
        return #result.done_responses > 0
      end)

      assert.equals(1, #result.done_responses)
      assert.is_true(result.done_responses[1]._cancelled)
      assert.equals("Cancelled", result.done_responses[1].error)
      -- The synthesized response still names its turn, which is what `_handle_response`'s staleness
      -- check compares, and the process, which is what the session read-back reads.
      assert.equals(result.handle_id, result.done_responses[1]._handle_id)
      assert.equals(result.process_id, result.done_responses[1]._process_id)
      assert.is_nil(ActiveStreamRegistry.get(result.handle_id))
    end)

    it("cancel takes a process id and not a turn id", function()
      -- The turn id addresses nothing in the process table, so passing one is a no-op rather than a
      -- kill. Under oneshot the two used to be one value, which is what hid every mis-assignment.
      local result = helper.run_stream(adapter)

      adapter:cancel(result.handle_id)
      vim.wait(100, function()
        return #result.done_responses > 0
      end)

      assert.equals(0, #result.done_responses, "the turn id cancelled a process")
      assert.is_not.equals(result.handle_id, result.process_id)
      assert.is_truthy(ActiveStreamRegistry.get(result.handle_id), "the stream was unregistered")

      adapter:cancel(result.process_id)
      vim.wait(200, function()
        return #result.done_responses > 0
      end)
      assert.equals(1, #result.done_responses)
    end)

    it("cancel forgets the handle so a later cancel is a no-op", function()
      helper.run_stream(adapter)
      adapter:cancel()
      assert.has_no.errors(function()
        adapter:cancel()
      end)
    end)

    it("cancel all keeps cancelling when one completion callback throws", function()
      local completed = {}
      adapter._processes = {
        h1 = {
          pid = 9001,
          kill = function() end,
          on_cancel = function()
            completed.h1 = true
            error("cleanup failed")
          end,
        },
        h2 = {
          pid = 9002,
          kill = function() end,
          on_cancel = function()
            completed.h2 = true
          end,
        },
      }

      local original_notify = vim.notify
      vim.notify = function() end
      local ok, err = pcall(function()
        adapter:cancel()
      end)
      vim.wait(20)
      vim.notify = original_notify
      assert.is_true(ok, tostring(err))

      assert.is_true(completed.h1)
      assert.is_true(completed.h2)
      assert.is_nil(adapter._processes.h1)
      assert.is_nil(adapter._processes.h2)
    end)

    it("execute cancels a run that never finishes rather than leaving it alive", function()
      -- The timeout is module-level state, so it is restored before the assertions rather than
      -- after: a failing assertion here would otherwise leave every later spec on a 50ms budget.
      local original_timeout = CliRuntime.INITIAL_RESPONSE_TIMEOUT_MS
      local original_cancel = adapter.cancel

      local cancelled_with = false
      adapter.cancel = function(self, process_id)
        cancelled_with = process_id
        return original_cancel(self, process_id)
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
