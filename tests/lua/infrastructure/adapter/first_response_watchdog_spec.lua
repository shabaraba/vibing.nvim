---@diagnostic disable: undefined-field
--- One answer to "how long until the CLI's first byte", and one shape for the response that says it
--- never came (#782).
---
--- Both transports used to carry their own copy of the budget, the error string and the payload,
--- with a comment on each telling the next person to keep them equal. These assertions are written
--- so that a copy coming back does not pass: the budget is asserted by *changing the shared value*
--- and watching both transports obey it, which a transport reading its own constant cannot do.
local helper = require("tests.helpers.adapter_stream")
local ClaudeAdapter = require("vibing.infrastructure.adapter.claude_cli")
local CliRuntime = require("vibing.infrastructure.adapter.modules.cli_runtime")
local DuplexTurn = require("vibing.infrastructure.adapter.modules.duplex_turn")
local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
local TurnOutcome = require("vibing.infrastructure.adapter.modules.turn_outcome")

local CHAT_BUFNR = 5150

--- Short enough that both transports' watchdogs fire inside a test, and nothing else here waits.
local TIMEOUT_MS = 60

--- How long a test is willing to wait for a 60ms watchdog, with room for a loaded machine.
local PATIENCE_MS = 2000

describe("the first-response watchdog", function()
  local original_timeout, original_notify, original_exepath

  before_each(function()
    original_timeout = TurnOutcome.FIRST_RESPONSE_TIMEOUT_MS
    TurnOutcome.FIRST_RESPONSE_TIMEOUT_MS = TIMEOUT_MS
    original_notify = vim.notify
    vim.notify = function() end
    helper.reset_path_caches()
  end)

  after_each(function()
    -- Restored here rather than inline so a failing assertion cannot leave every later spec in the
    -- run on a 60ms budget.
    TurnOutcome.FIRST_RESPONSE_TIMEOUT_MS = original_timeout
    vim.notify = original_notify
    if original_exepath then
      vim.fn.exepath = original_exepath
      original_exepath = nil
    end
    helper.reset_path_caches()
  end)

  --- Run one oneshot turn that resumes a session and never answers.
  --- @return table response the single response the turn produced
  --- @return table adapter the adapter that ran it, for asserting the hung process is gone
  local function oneshot_timeout_response()
    local system = helper.stub_system()
    local adapter = ClaudeAdapter:new({
      agent = { default_model = "sonnet", plugins = { self = false, project_dir = false } },
    })
    -- `stub_system` never invokes `on_exit`, so the watchdog is the only thing that can end this
    -- turn: no response at all is the failure this test is looking for.
    local result = helper.run_stream(adapter, { _session_id = "sess-oneshot" })
    vim.wait(PATIENCE_MS, function()
      return #result.done_responses > 0
    end, 10)
    system.restore()

    assert.equals(1, #result.done_responses, "the oneshot watchdog never fired on the shared budget")
    return result.done_responses[1], adapter
  end

  --- Run one duplex turn that never answers.
  --- @return table response
  local function duplex_timeout_response()
    local jobs = helper.stub_jobstart()
    original_exepath = vim.fn.exepath
    vim.fn.exepath = function()
      return helper.fake_binary("watchdog-claude")
    end
    local adapter = ClaudeAdapter:new({
      agent = { default_model = "sonnet", plugins = { self = false, project_dir = false } },
      backends = { claude = { process = "duplex" } },
    })

    local responses = {}
    adapter:stream("hi", { chat_bufnr = CHAT_BUFNR, permissions_allow = {}, _session_id = "sess-duplex" }, function() end, function(response)
      table.insert(responses, response)
    end)
    vim.wait(PATIENCE_MS, function()
      return #responses > 0
    end, 10)

    Pool._reset()
    jobs.restore()

    assert.equals(1, #responses, "the duplex watchdog never fired on the shared budget")
    return responses[1]
  end

  describe("the budget", function()
    it("has one home, which both transports read at the moment they arm", function()
      -- The assertion is the *override*: `TurnOutcome.FIRST_RESPONSE_TIMEOUT_MS` was set to 60ms in
      -- `before_each`, and a transport that kept a constant of its own -- or aliased this one at
      -- module load, which is what `cli_adapter` did -- would still be sitting on 120000 here and
      -- would produce no response inside `PATIENCE_MS`.
      assert.equals("Session resume timeout", oneshot_timeout_response().error)
      assert.equals("Session resume timeout", duplex_timeout_response().error)
    end)

    it("is not also defined by either transport", function()
      -- A re-added copy nothing reads is harmless today and is how the drift comes back tomorrow.
      assert.is_nil(CliRuntime.INITIAL_RESPONSE_TIMEOUT_MS)
      assert.is_nil(CliRuntime.FIRST_RESPONSE_TIMEOUT_MS)
      assert.is_nil(DuplexTurn.FIRST_RESPONSE_TIMEOUT_MS)
    end)
  end)

  describe("the response", function()
    it("is the same on both transports, apart from the ids", function()
      local oneshot = oneshot_timeout_response()
      local duplex = duplex_timeout_response()

      for _, response in ipairs({ oneshot, duplex }) do
        -- The two fields the chat layer acts on: `_session_corrupted` routes `_handle_response`
        -- into the session reset, and `content` is empty because by definition nothing arrived.
        assert.is_true(response._session_corrupted)
        assert.equals("Session resume timeout", response.error)
        assert.equals("", response.content)
        assert.is_string(response._turn_id)
        assert.is_string(response._process_id)
      end
    end)

    it("survives the kill that follows it, on the oneshot transport too", function()
      -- The bug the merge exposed. `cancel()` completes the same turn as a plain "Cancelled", and
      -- `finish` is idempotent, so the oneshot path's "kill, then report" ordering threw the
      -- timeout response away: the session was never reset, no notice was written, and
      -- `_cancelled` suppressed the error line as well. A hung resumed session ended the turn with
      -- an empty assistant section and no message of any kind.
      local response, adapter = oneshot_timeout_response()

      assert.is_not_true(response._cancelled, "the kill's own response replaced the timeout's")
      assert.is_true(response._session_corrupted, "the session would never have been reset")
      -- Reordering must not have traded the response for the kill: the whole point of this
      -- watchdog is that a hung CLI does not outlive the turn that started it.
      assert.same({}, adapter._processes, "the hung process was left registered and alive")
    end)
  end)

  describe("the response constructors", function()
    local IDS = { turn_id = "turn-1", process_id = "proc-1" }

    it("put both ids on every response, including ones built before a process existed", function()
      for _, response in ipairs({
        TurnOutcome.ended(IDS, "", "boom"),
        TurnOutcome.cancelled(IDS, ""),
        TurnOutcome.first_response_timeout(IDS),
      }) do
        assert.equals("turn-1", response._turn_id)
        assert.equals("proc-1", response._process_id)
      end
    end)

    it("marks only a cancellation as cancelled, so nothing else is silenced in the chat", function()
      assert.is_true(TurnOutcome.cancelled(IDS, "partial")._cancelled)
      assert.equals("partial", TurnOutcome.cancelled(IDS, "partial").content)
      assert.is_nil(TurnOutcome.ended(IDS, "out", "boom")._cancelled)
      assert.is_nil(TurnOutcome.first_response_timeout(IDS)._cancelled)
    end)

    it("leaves error nil for a turn that simply finished", function()
      local response = TurnOutcome.ended(IDS, "hello", nil)
      assert.is_nil(response.error)
      assert.equals("hello", response.content)
    end)
  end)

  describe("where a response may be built", function()
    it("is turn_outcome.lua and nowhere else in the adapter layer", function()
      -- The failure this guards is the one this repository keeps repeating: the discipline is
      -- followed at the call sites the author had in mind and a third one is missed, after which
      -- every test still passes. There were eleven response literals before #782; a twelfth
      -- written by hand fails here rather than drifting quietly.
      local root = "lua/vibing/infrastructure/adapter"
      local offenders = {}
      for _, path in ipairs(vim.fn.glob(root .. "/**/*.lua", false, true)) do
        if not path:find("turn_outcome%.lua$") then
          for number, line in ipairs(vim.fn.readfile(path)) do
            -- `_turn_id` preceded by a non-word character, so `active_turn_id` does not match, and
            -- followed by a single `=`, so a comparison does not either.
            if line:find("[^%w_]_turn_id%s*=[^=]") then
              table.insert(offenders, path .. ":" .. number .. ": " .. vim.trim(line))
            end
          end
        end
      end
      assert.same({}, offenders, "a Vibing.Response is built outside turn_outcome.lua")
    end)
  end)
end)
