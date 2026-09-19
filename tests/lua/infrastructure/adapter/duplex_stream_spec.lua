---@diagnostic disable: undefined-field
--- The resident transport, driven through the real `stream()` with `jobstart` stubbed (#777).
---
--- Everything here is about the two lifetimes coming apart: a turn ends on the CLI's `result` line
--- while the process that produced it stays registered, alive, and holding its session.
local helper = require("tests.helpers.adapter_stream")
local ClaudeAdapter = require("vibing.infrastructure.adapter.claude_cli")
local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
local ProcessRegistry = require("vibing.infrastructure.adapter.modules.process_registry")
local TurnRegistry = require("vibing.infrastructure.adapter.modules.turn_registry")
local Permission = require("vibing.infrastructure.rpc.handlers.permission")

local CHAT_BUFNR = 4242

--- The interrupt's kill fallback, shortened for the two tests that have to wait it out.
---
--- The real value is 5s, and two tests waiting it out really is 12 seconds added to `npm test` for
--- nothing — the fallback's behaviour has no relationship to its length. Overridden the way
--- `cli_runtime_spec` overrides `INITIAL_RESPONSE_TIMEOUT_MS`, and restored in `after_each` rather
--- than inline so a failing assertion cannot leave every later spec on a 100ms budget.
local GRACE_MS = 100

--- A `result` line ends a turn; everything else here is what a real stream carries around it.
local function result_line(session_id, subtype)
  return vim.json.encode({ type = "result", subtype = subtype or "success", session_id = session_id })
end

local function init_line(session_id)
  return vim.json.encode({ type = "system", subtype = "init", session_id = session_id, claude_code_version = "2.1.273" })
end

local function text_line(session_id, text)
  return vim.json.encode({
    type = "stream_event",
    session_id = session_id,
    event = { type = "content_block_delta", delta = { type = "text_delta", text = text } },
  })
end

describe("duplex transport", function()
  local jobs, adapter, config
  local Routing = require("vibing.infrastructure.adapter.modules.duplex_routing")
  local original_grace
  -- `stub_jobstart` does not own `exepath` — only `stub_system` saves and restores it. Left
  -- assigned, every later spec in the run resolves any executable to this one.
  local original_exepath

  before_each(function()
    original_grace = Routing.INTERRUPT_GRACE_MS
    Routing.INTERRUPT_GRACE_MS = GRACE_MS
    jobs = helper.stub_jobstart()
    helper.reset_path_caches()
    original_exepath = vim.fn.exepath
    vim.fn.exepath = function()
      return helper.fake_binary("duplex-claude")
    end
    config = {
      agent = { default_model = "sonnet", plugins = { self = false, project_dir = false } },
      backends = { claude = { process = "duplex" } },
    }
    adapter = ClaudeAdapter:new(config)
  end)

  after_each(function()
    Routing.INTERRUPT_GRACE_MS = original_grace
    Pool._reset()
    jobs.restore()
    vim.fn.exepath = original_exepath
    helper.reset_path_caches()
  end)

  --- Start a turn and return what `stream()` handed back plus the responses it produced.
  local function send(prompt, extra)
    local responses = {}
    local chunks = {}
    local turn_id, process_id = adapter:stream(
      prompt,
      vim.tbl_extend("force", { chat_bufnr = CHAT_BUFNR, permissions_allow = {} }, extra or {}),
      function(chunk)
        table.insert(chunks, chunk)
      end,
      function(response)
        table.insert(responses, response)
      end
    )
    return { turn_id = turn_id, process_id = process_id, responses = responses, chunks = chunks }
  end

  describe("the argv", function()
    it("takes its prompt on stdin instead of in the argv", function()
      local turn = send("what is the airspeed velocity")
      local call = jobs.only_call()

      assert.is_false(vim.tbl_contains(call.argv, "what is the airspeed velocity"))
      assert.same(
        { type = "user", message = { role = "user", content = "what is the airspeed velocity" } },
        jobs.sent(call)[1]
      )
      assert.is_not_nil(turn.turn_id)
    end)

    it("asks the CLI to read stdin as stream-json", function()
      local call = (send("hi") and jobs.only_call())
      local index = vim.fn.index(call.argv, "--input-format")
      assert.is_true(index >= 0, "no --input-format in " .. table.concat(call.argv, " "))
      assert.equals("stream-json", call.argv[index + 2])
    end)

    it("leaves the oneshot argv alone when the chat did not opt in", function()
      config.backends.claude.process = "oneshot"
      local system = helper.stub_system()
      send("hi")
      assert.equals(0, #jobs.calls)
      assert.is_true(vim.tbl_contains(system.cli_call().cmd, "hi"))
      system.restore()
    end)
  end)

  describe("a turn", function()
    it("ends on the result line, with the process still alive and registered", function()
      local turn = send("hi")
      local call = jobs.only_call()

      jobs.emit(call, { init_line("sess-1"), text_line("sess-1", "hello") })
      assert.equals(0, #turn.responses, "a turn must not end before its result line")

      jobs.emit(call, { result_line("sess-1") })
      assert.equals(1, #turn.responses)
      assert.is_nil(turn.responses[1].error)
      assert.equals(turn.turn_id, turn.responses[1]._turn_id)

      assert.is_false(call.stopped, "the process was stopped at the end of its turn")
      assert.is_not_nil(ProcessRegistry.get(turn.process_id))
      assert.is_nil(TurnRegistry.get(turn.turn_id), "the turn outlived its result")
    end)

    it("carries the CLI's declared failure out as the turn's error", function()
      local turn = send("hi")
      local call = jobs.only_call()
      jobs.emit(call, {
        vim.json.encode({ type = "result", subtype = "error", is_error = true, result = "boom", session_id = "sess-1" }),
      })

      assert.equals(1, #turn.responses)
      assert.equals("boom", turn.responses[1].error)
    end)

    it("clears its permission opts so the next turn cannot inherit them", function()
      local turn = send("hi", { permission_mode = "plan" })
      assert.is_not_nil(Permission._get_active_opts(turn.turn_id))

      jobs.emit(jobs.only_call(), { result_line("sess-1") })
      assert.is_nil(Permission._get_active_opts(turn.turn_id))
    end)
  end)

  describe("the second turn", function()
    --- Run one full turn and hand back the job it ran on.
    local function first_turn()
      local turn = send("first")
      local call = jobs.only_call()
      jobs.emit(call, { init_line("sess-1"), result_line("sess-1") })
      return turn, call
    end

    it("runs on the same process, with no second spawn", function()
      local first = first_turn()
      local second = send("second", { _session_id = "sess-1" })

      assert.equals(1, #jobs.calls, "the second turn spawned a process of its own")
      assert.equals(first.process_id, second.process_id)
      assert.are_not.equals(first.turn_id, second.turn_id)
      assert.same({ type = "user", message = { role = "user", content = "second" } }, jobs.sent(jobs.calls[1])[2])
    end)

    it("starts with its own subagent count, not the one the last turn abandoned", function()
      -- `processes-and-turns.md` -> "What is still owed": a Task whose tool_result never lands
      -- would otherwise be a permanent contribution to `total_subagent_count()` and throttle every
      -- chat through `concurrency.at_capacity()`.
      local first = first_turn()
      local call = jobs.calls[1]
      TurnRegistry.increment_subagent_count(first.turn_id)

      local second = send("second", { _session_id = "sess-1" })
      assert.equals(0, TurnRegistry.get(second.turn_id).subagent_count)
      assert.equals(0, TurnRegistry.total_subagent_count())
      jobs.emit(call, { result_line("sess-1") })
    end)

    it("runs under its own permission opts", function()
      local first = first_turn()
      local second = send("second", { _session_id = "sess-1", permission_mode = "acceptEdits" })

      assert.equals("acceptEdits", Permission._get_active_opts(second.turn_id).permission_mode)
      assert.is_nil(Permission._get_active_opts(first.turn_id))
    end)

    it("does not re-announce the session it has already reported", function()
      -- The decoder's parse state belongs to the process, not the turn; a fresh state per turn
      -- would emit a `session` event on the first line of every turn.
      local first = first_turn()
      local sessions = {}
      local original = require("vibing.infrastructure.adapter.modules.session_manager").store
      require("vibing.infrastructure.adapter.modules.session_manager").store = function(self, process_id, session_id)
        table.insert(sessions, session_id)
        return original(self, process_id, session_id)
      end

      send("second", { _session_id = "sess-1" })
      jobs.emit(jobs.calls[1], { text_line("sess-1", "x"), result_line("sess-1") })
      require("vibing.infrastructure.adapter.modules.session_manager").store = original

      assert.same({}, sessions)
      assert.equals("sess-1", adapter:get_session_id(first.process_id))
    end)
  end)

  describe("restarting", function()
    it("replaces the process when the argv would have changed, and resumes the session", function()
      -- `transports.wanted` and the permission argv are decided per turn, but a resident process
      -- was handed its flags once. A turn the live process cannot honestly serve gets a new one.
      local first = send("first")
      jobs.emit(jobs.calls[1], { init_line("sess-1"), result_line("sess-1") })

      local second = send("second", { _session_id = "sess-1", permission_mode = "bypassPermissions" })

      assert.equals(2, #jobs.calls, "the changed argv did not restart the process")
      assert.is_true(jobs.calls[1].stopped)
      assert.are_not.equals(first.process_id, second.process_id)
      assert.is_true(vim.tbl_contains(jobs.calls[2].argv, "--resume"))
      assert.is_true(vim.tbl_contains(jobs.calls[2].argv, "sess-1"))
      assert.is_nil(ProcessRegistry.get(first.process_id))
    end)

    it("does not let the replaced process's exit tear down its replacement", function()
      -- `jobstop` only *asks*. Neovim flushes the job's streams before firing `on_exit`, so the
      -- dying process's callback always lands after the pool has installed the replacement under
      -- the same chat key. A callback that asked "what is registered for this chat?" rather than
      -- "am I still the registered one?" then unregistered the replacement, killed its open turn
      -- with a bogus exit code, and orphaned a live ~200MB CLI that no reclaim route could reach.
      send("first")
      jobs.emit(jobs.calls[1], { init_line("sess-1"), result_line("sess-1") })
      local second = send("second", { _session_id = "sess-1", permission_mode = "bypassPermissions" })
      assert.equals(2, #jobs.calls, "the changed argv should have started a replacement")

      jobs.flush_exits()

      assert.equals(0, #second.responses, "the replacement's turn was ended by the old process's exit")
      assert.is_not_nil(ProcessRegistry.get(second.process_id), "the replacement was unregistered")
      assert.is_not_nil(Pool.get(CHAT_BUFNR), "the replacement was orphaned; no reclaim route can reach it")
      assert.is_not_nil(adapter._processes[second.process_id])

      jobs.emit(jobs.calls[2], { result_line("sess-1") })
      assert.equals(1, #second.responses)
      assert.is_nil(second.responses[1].error)
    end)

    it("still routes stdout to the turn that owns it after a replacement", function()
      -- Same root cause, second symptom: whatever the dying process flushes must not be decoded
      -- into the replacement's turn. A `result` among those bytes would end the new turn before it
      -- had produced anything.
      send("first")
      jobs.emit(jobs.calls[1], { init_line("sess-1"), result_line("sess-1") })
      local second = send("second", { _session_id = "sess-1", permission_mode = "bypassPermissions" })

      jobs.emit(jobs.calls[1], { result_line("sess-1") })

      assert.equals(0, #second.responses, "the dead process's output completed the live turn")
    end)

    it("does not restart merely because the second turn has a session and the first did not", function()
      -- The reuse key is built with no session id for exactly this reason: `--resume` appearing on
      -- turn 2 and not on turn 1 would restart every chat's process on its second turn.
      send("first")
      jobs.emit(jobs.calls[1], { init_line("sess-1"), result_line("sess-1") })
      send("second", { _session_id = "sess-1" })

      assert.equals(1, #jobs.calls)
    end)
  end)

  describe("interrupting", function()
    it("stops the turn and leaves the process running", function()
      local turn = send("hi")
      local call = jobs.only_call()

      adapter:stop_turn(turn.process_id)
      assert.is_false(call.stopped)
      local sent = jobs.sent(call)
      assert.equals("control_request", sent[2].type)
      assert.equals("interrupt", sent[2].request.subtype)

      -- The CLI answers an interrupt with a result of its own, and that is what ends the turn.
      jobs.emit(call, { result_line("sess-1", "error_during_execution") })
      assert.equals(1, #turn.responses)

      local next_turn = send("again", { _session_id = "sess-1" })
      assert.equals(1, #jobs.calls)
      assert.equals(turn.process_id, next_turn.process_id)
    end)

    it("does nothing at all to a process that is between turns", function()
      -- `ChatBuffer:send_message` calls `cancel_request()` before *every* message as a zombie
      -- reap, so on this transport the common case is being asked to stop an idle process. If
      -- `stop_turn` reported that as unhandled, its caller's fallback is a kill -- and the
      -- resident process would be thrown away before every single message.
      local turn = send("hi")
      local call = jobs.only_call()
      jobs.emit(call, { init_line("sess-1"), result_line("sess-1") })

      adapter:stop_turn(turn.process_id)
      assert.is_false(call.stopped)
      assert.equals(1, #jobs.sent(call), "an idle process was sent an interrupt")

      local second = send("second", { _session_id = "sess-1" })
      assert.equals(1, #jobs.calls)
      assert.equals(turn.process_id, second.process_id)
    end)

    it("kills the process when the interrupt does not stop the turn in time", function()
      -- `chansend` succeeding means the bytes were written, never that the CLI acted on them, and
      -- one wedged inside a tool call will not. The contract the user sees is "if I say stop, it
      -- stops"; keeping the process alive is an optimisation underneath that, not a replacement.
      local warnings = {}
      local original_notify = vim.notify
      vim.notify = function(message, level)
        table.insert(warnings, { message = message, level = level })
      end

      local turn = send("hi")
      local call = jobs.only_call()
      jobs.emit(call, { init_line("sess-1") })
      adapter:stop_turn(turn.process_id)

      -- The CLI answers nothing at all: no control_response, no result.
      vim.wait(GRACE_MS + 200, function()
        return #turn.responses > 0
      end, 10)
      vim.notify = original_notify

      assert.is_true(call.stopped, "the wedged process survived the grace period")
      assert.equals(1, #turn.responses)
      assert.is_true(turn.responses[1]._cancelled)
      local told = vim.tbl_filter(function(entry)
        return entry.message:find("interrupted", 1, true) ~= nil
      end, warnings)
      assert.equals(1, #told, "the fallback fired without telling anyone")
    end)

    it("disarms the kill fallback when the interrupt does work", function()
      -- The worst available bug shape: a watchdog that outlives its turn fires during the *next*
      -- one, on the same resident process, and kills that instead.
      local turn = send("hi")
      local call = jobs.only_call()
      jobs.emit(call, { init_line("sess-1") })

      adapter:stop_turn(turn.process_id)
      jobs.emit(call, { result_line("sess-1", "error_during_execution") })
      assert.equals(1, #turn.responses)

      local second = send("second", { _session_id = "sess-1" })
      vim.wait(GRACE_MS + 200, function()
        return #second.responses > 0
      end, 10)

      assert.equals(0, #second.responses, "the previous turn's watchdog killed this turn")
      assert.is_false(call.stopped)
      jobs.emit(call, { result_line("sess-1") })
    end)

    it("falls through to the kill when the interrupt cannot even be written", function()
      -- "This is a resident process, do not kill it" and "the interrupt was delivered" are two
      -- different facts. Reporting the first as though it were the second turns the user's cancel
      -- into a no-op against a process whose stdin is already gone -- recoverable only when the
      -- grace timer eventually notices, which is a long time to watch a cancel do nothing.
      local turn = send("hi")
      local call = jobs.only_call()
      jobs.emit(call, { init_line("sess-1") })

      local original = vim.fn.chansend
      vim.fn.chansend = function()
        return 0
      end
      adapter:stop_turn(turn.process_id)
      vim.fn.chansend = original

      assert.is_true(call.stopped, "an unreachable process survived the user's cancel")
      assert.equals(1, #turn.responses)
      assert.is_true(turn.responses[1]._cancelled)
    end)

    it("is not what cancel() does, which still kills a resident process outright", function()
      -- `permission.lua`'s `cancel_and_deny` goes through `cancel`, and it relies on the process
      -- being gone afterwards; only the user-facing stop is routed through `stop_turn`.
      local turn = send("hi")
      adapter:cancel(turn.process_id)

      assert.is_true(jobs.only_call().stopped)
      assert.equals(1, #turn.responses)
      assert.is_true(turn.responses[1]._cancelled)
    end)
  end)

  describe("a second send while a turn is still open", function()
    it("ends the first turn rather than stacking a second one on the same process", function()
      -- `ChatBuffer:send_message` guards only `_is_sending`, the <CR>-to-spawn window, and relied
      -- on `cancel_request` closing the previous turn synchronously. That is true of a kill and
      -- not of an interrupt, so routing the user's cancel through `stop_turn` opened this hole.
      local first = send("hi")
      jobs.emit(jobs.only_call(), { init_line("sess-1") })

      local second = send("second", { _session_id = "sess-1" })

      assert.equals(1, #first.responses, "the first turn was orphaned with no response at all")
      assert.is_true(first.responses[1]._cancelled)
      assert.is_nil(TurnRegistry.get(first.turn_id), "the orphaned turn leaked its registry entry")
      assert.is_nil(Permission._get_active_opts(first.turn_id), "the orphaned turn leaked its permission opts")
      assert.are_not.equals(first.process_id, second.process_id, "the second turn reused a busy process")
    end)

    it("does not let the abandoned turn's result complete the new one", function()
      local first = send("hi")
      jobs.emit(jobs.calls[1], { init_line("sess-1") })
      local second = send("second", { _session_id = "sess-1" })

      -- The interrupted first turn answers late, on the process it belonged to.
      jobs.emit(jobs.calls[1], { result_line("sess-1", "error_during_execution") })

      assert.equals(1, #first.responses, "the late result completed the first turn twice")
      assert.equals(0, #second.responses, "the first turn's result completed the second turn")
    end)
  end)

  describe("a turn that reports a failure and then kills the process", function()
    it("keeps the reason it failed, rather than the kill's bare cancellation", function()
      -- `Pool.stop` completes the open turn as "Cancelled" on its way out, and `complete` is
      -- idempotent, so whichever runs first wins. Killing before reporting therefore replaced the
      -- caller's own response -- and on the watchdog path that took `_session_corrupted` with it,
      -- so the session was never reset, while `_cancelled` suppressed the error line too: a hung
      -- process ended the turn with an empty assistant section and no message of any kind.
      local original = vim.fn.chansend
      vim.fn.chansend = function()
        return 0
      end
      local turn = send("hi")
      vim.fn.chansend = original

      assert.equals(1, #turn.responses)
      assert.matches("Could not write the prompt", turn.responses[1].error)
      assert.is_not_true(turn.responses[1]._cancelled, "the kill's response replaced the real one")
      assert.is_true(jobs.only_call().stopped, "the unusable process was left running")
    end)
  end)

  describe("writing to a process that is already gone", function()
    it("is a failure, not a success, when chansend writes nothing", function()
      -- A killed job keeps a valid channel id until its `on_exit` runs, so `is_alive` still says
      -- yes and `chansend` quietly returns 0. Treating that as sent binds the turn to a dying
      -- process, which then waits out the whole first-response watchdog.
      local DuplexProcess = require("vibing.infrastructure.adapter.modules.duplex_process")
      local original = vim.fn.chansend
      vim.fn.chansend = function()
        return 0
      end
      local sent = DuplexProcess.send_prompt({ job_id = 1, pid = 2 }, "hi")
      vim.fn.chansend = original

      assert.is_false(sent)
    end)
  end)

  describe("a process that dies", function()
    it("fails the turn it had open rather than leaving the chat waiting", function()
      local turn = send("hi")
      jobs.exit(jobs.only_call(), 1)

      assert.equals(1, #turn.responses)
      assert.matches("exited with code 1", turn.responses[1].error)
      assert.is_nil(ProcessRegistry.get(turn.process_id))
      assert.is_nil(TurnRegistry.get(turn.turn_id))
    end)

    it("is forgotten by the adapter on every route out, not only its own exit", function()
      -- Four routes reclaim a process and only one of them arrives as an `on_exit`. A route that
      -- announced nothing left `adapter._processes` holding a handle to a process that no longer
      -- exists, which `cleanup_stale_sessions` then reads as "still running" forever.
      local turn = send("hi")
      jobs.emit(jobs.only_call(), { init_line("sess-1"), result_line("sess-1") })
      assert.is_not_nil(adapter._processes[turn.process_id])

      Pool.stop(CHAT_BUFNR)

      assert.is_nil(adapter._processes[turn.process_id])
      assert.is_nil(ProcessRegistry.get(turn.process_id))
      assert.is_true(jobs.calls[1].stopped)
    end)

    it("reports a turn killed mid-flight as cancelled, not as an exit code", function()
      local turn = send("hi")
      Pool.stop(CHAT_BUFNR)

      assert.equals(1, #turn.responses)
      assert.equals("Cancelled", turn.responses[1].error)
      assert.is_true(turn.responses[1]._cancelled)
    end)

    it("is replaced on the next turn, resuming where it left off", function()
      local first = send("hi")
      jobs.emit(jobs.calls[1], { init_line("sess-1") })
      jobs.exit(jobs.calls[1], 1)

      local second = send("again", { _session_id = "sess-1" })
      assert.equals(2, #jobs.calls)
      assert.are_not.equals(first.process_id, second.process_id)
      assert.is_true(vim.tbl_contains(jobs.calls[2].argv, "sess-1"))
    end)
  end)
end)
