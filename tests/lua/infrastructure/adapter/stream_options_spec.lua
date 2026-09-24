---@diagnostic disable: undefined-field
--- Covers what `stream()` sets up before the process exists, across all three adapters at once.
--- Previously untested: #510's review flagged it, #514 is the follow-up.
local helper = require("tests.helpers.adapter_stream")
local TurnRegistry = require("vibing.infrastructure.adapter.modules.turn_registry")
local perm_handler = require("vibing.infrastructure.rpc.handlers.permission")

local CONFIG = { agent = { default_model = "sonnet" } }

for _, backend in ipairs(helper.adapters()) do
  describe("adapter stream() options: " .. backend.name, function()
    local system, adapter

    before_each(function()
      system = helper.stub_system()
      adapter = backend.module:new(CONFIG)
    end)

    after_each(function()
      system.restore()
    end)

    describe("vim.system options", function()
      it("asks for text mode so handlers get strings, not byte chunks", function()
        helper.run_stream(adapter)
        assert.is_true(system.only_call().opts.text)
      end)

      it("runs in the requested working directory", function()
        helper.run_stream(adapter, { cwd = "/tmp/some-worktree" })
        assert.equals("/tmp/some-worktree", system.only_call().opts.cwd)
      end)

      it("installs stdout and stderr handlers and an exit callback", function()
        helper.run_stream(adapter)
        local call = system.only_call()
        assert.is_function(call.opts.stdout)
        assert.is_function(call.opts.stderr)
        assert.is_function(call.on_exit)
      end)
    end)

    describe("environment", function()
      it("tags the child so hooks know they are inside vibing.nvim", function()
        helper.run_stream(adapter)
        local env = system.only_call().opts.env
        assert.equals("9999", env.VIBING_NVIM_RPC_PORT)
        assert.equals("true", env.VIBING_NVIM_CONTEXT)
      end)

      it("passes the process id, not the turn id, so a resident process can still be named", function()
        -- The whole wire contract in one assertion, over every backend: an environment variable is
        -- fixed at spawn, so it may only ever carry the process. `rpc/hook_scope.lua` resolves the
        -- turn in-editor, and that is what keeps concurrent chats from cross-wiring their approval
        -- UI. Carrying the turn id here would work today and break on the first resident process.
        --
        -- Deliberately not asserting that `VIBING_HANDLE_ID` is gone: the child environment starts
        -- from `vim.fn.environ()`, and this repository is normally developed from inside a
        -- vibing.nvim chat, so the *outer* Neovim's own variable is present here whatever this code
        -- exports. The assertion would pass or fail on how the suite was launched.
        local result = helper.run_stream(adapter)
        local env = system.only_call().opts.env
        assert.equals(result.process_id, env.VIBING_PROCESS_ID)
        assert.is_not.equals(result.turn_id, env.VIBING_PROCESS_ID)
      end)

      it("registers the same process id the child was told about", function()
        -- The join the hook depends on: what the shell sends must address the registry entry, or
        -- every permission decision resolves to nil and the turn stalls until the hook fails closed.
        local result = helper.run_stream(adapter)
        local entry = require("vibing.infrastructure.adapter.modules.turn_registry").of_process(
          system.only_call().opts.env.VIBING_PROCESS_ID
        )
        assert.is_truthy(entry, "the exported process id addresses no registry entry")
        assert.equals(result.turn_id, entry.turn_id)
      end)

      it("inherits the parent environment rather than starting from empty", function()
        helper.run_stream(adapter)
        assert.is_not_nil(system.only_call().opts.env.PATH)
      end)
    end)

    describe("callbacks", function()
      it("passes the turn id to on_chunk so a late chunk can be told from a new turn's", function()
        -- grok used to call on_chunk(chunk) alone, so a chunk arriving after the user had sent
        -- something new was appended to the wrong turn. One stream() means one calling convention.
        -- Every processor emits through context.onChunk, so the context is captured where the
        -- adapter hands it to the stdout handler rather than by feeding backend-specific JSON.
        local StreamHandler = require("vibing.infrastructure.adapter.modules.stream_handler")
        local original = StreamHandler.create_stdout_handler
        local captured = nil
        StreamHandler.create_stdout_handler = function(processor, context, is_cancelled)
          captured = context
          return original(processor, context, is_cancelled)
        end

        local seen = nil
        local turn_id = adapter:stream("hello", { permissions_allow = {} }, function(_, chunk_turn_id)
          seen = chunk_turn_id
        end, function() end)
        StreamHandler.create_stdout_handler = original

        captured.onChunk("x")
        assert.equals(turn_id, seen)
      end)

      it("registers the session id it is resuming, so a second buffer on that session is refused", function()
        -- On the **process**, not the turn: a process holds its `--resume` between turns.
        local result = helper.run_stream(adapter, { _session_id = "sess-shared" })
        assert.equals("sess-shared", TurnRegistry.get(result.turn_id).process.session_id)
      end)
    end)

    describe("turn registry", function()
      it("registers the turn while the process runs", function()
        local result = helper.run_stream(adapter)
        assert.is_not_nil(TurnRegistry.get(result.turn_id))
      end)

      it("unregisters once the process exits", function()
        local result = helper.run_stream(adapter)
        system.only_call().on_exit({ code = 0, stdout = "", stderr = "" })
        vim.wait(200, function()
          return TurnRegistry.get(result.turn_id) == nil
        end)
        assert.is_nil(TurnRegistry.get(result.turn_id))
      end)

      it("clears the permission opts once the process exits", function()
        local result = helper.run_stream(adapter, { permissions_deny = { "Bash" } })
        assert.same({ "Bash" }, perm_handler._get_active_opts(result.turn_id).permissions_deny)

        system.only_call().on_exit({ code = 0, stdout = "", stderr = "" })
        vim.wait(200, function()
          return perm_handler._get_active_opts(result.turn_id) == nil
        end)
        -- clear_active_opts is what stream() promises to call; opening a fresh turn must
        -- not see the old one's deny list.
        assert.is_nil(perm_handler._get_active_opts(result.turn_id))
      end)
    end)

    describe("on_done", function()
      it("fires exactly once even if the exit callback runs twice", function()
        -- The guard this covers: cancel() and a natural exit can both land, and the caller must
        -- not be told the turn finished twice.
        local result = helper.run_stream(adapter)
        local on_exit = system.only_call().on_exit

        on_exit({ code = 0, stdout = "", stderr = "" })
        on_exit({ code = 0, stdout = "", stderr = "" })
        vim.wait(200, function()
          return #result.done_responses > 0
        end)

        assert.equals(1, #result.done_responses)
      end)

      it("reports a usage limit so the chat parks instead of erroring out", function()
        -- Auto-resume was claude-only for as long as this merge was written inline in
        -- claude_cli.lua. Asserted here, across every registered backend, rather than by grepping
        -- for the call: a backend that skips it stops at `**Error:**` and never resumes.
        local result = helper.run_stream(adapter)
        local call = system.only_call()

        call.opts.stderr(nil, "You have hit your usage limit. Try again later.")
        call.on_exit({ code = 1, stdout = "", stderr = "" })
        vim.wait(200, function()
          return #result.done_responses > 0
        end)

        local info = result.done_responses[1]._rate_limit_info
        assert.is_not_nil(info)
        assert.is_true(info.rejected)
      end)

      it("leaves an ordinary failure alone", function()
        local result = helper.run_stream(adapter)
        local call = system.only_call()

        call.opts.stderr(nil, "ENOENT: no such file or directory")
        call.on_exit({ code = 1, stdout = "", stderr = "" })
        vim.wait(200, function()
          return #result.done_responses > 0
        end)

        assert.is_nil(result.done_responses[1]._rate_limit_info)
      end)
    end)

    describe("failures before spawn", function()
      it("reports a missing binary through on_done instead of throwing", function()
        -- send_message.lua does not wrap stream() in pcall, so a missing CLI must arrive as a
        -- response with an error, not as a Lua stack trace in the chat buffer.
        system.restore()
        system = helper.stub_system("")
        helper.reset_path_caches()

        local result = helper.run_stream(adapter)
        vim.wait(200, function()
          return #result.done_responses > 0
        end)

        assert.equals(1, #result.done_responses)
        assert.is_not_nil(result.done_responses[1].error)
        assert.equals(0, #system.calls, "no process should be spawned when the CLI is missing")
      end)

      it("reports a spawn that raises, instead of throwing out of stream()", function()
        -- #593's second half. A binary can go missing between the builder resolving it and the
        -- spawn, and libuv answers that with a raw `ENOENT: ... (cmd): '<path>'` that vim.system
        -- raises. Unguarded, that reaches the user as a Lua stack trace and leaves the turn
        -- registered, because the exit handler that unregisters it never runs.
        vim.system = function()
          error("ENOENT: no such file or directory (cmd): '/gone/cli'")
        end

        local result = helper.run_stream(adapter)
        vim.wait(200, function()
          return #result.done_responses > 0
        end)

        assert.equals(1, #result.done_responses)
        -- The wording itself is cli_runtime_spec's business; what matters here is that the adapter
        -- routes through it rather than handing libuv's text to the chat.
        local message = result.done_responses[1].error or ""
        assert.is_nil(message:find("ENOENT", 1, true), "raw libuv error leaked: " .. message)
        assert.is_nil(TurnRegistry.get(result.turn_id), "the turn outlived the failed spawn")
      end)

      it("strips the Lua file:line prefix so the chat shows a message, not a stack location", function()
        system.restore()
        system = helper.stub_system("")
        helper.reset_path_caches()

        local result = helper.run_stream(adapter)
        vim.wait(200, function()
          return #result.done_responses > 0
        end)

        local message = result.done_responses[1].error
        assert.is_nil(message:find("%.lua:%d+:"), "internal path leaked into the error: " .. message)
      end)
    end)
  end)
end

describe("adapter stream() options: stdin", function()
  -- claude reads its prompt from argv; codex, copilot, grok and pi are given an explicit empty
  -- stdin so they do not sit waiting on a terminal that isn't there. For pi it is not a precaution
  -- but a measured requirement: with stdin left open, `pi --mode json` never issues a request at
  -- all and produces no output, silently, until it is killed (Pi 0.87.1).
  local STDIN_BY_BACKEND = { claude = nil, codex = "", copilot = "", grok = "", pi = "" }

  for _, backend in ipairs(helper.adapters()) do
    it("matches the documented stdin handling for " .. backend.name, function()
      local system = helper.stub_system()
      local adapter = backend.module:new(CONFIG)

      helper.run_stream(adapter)

      assert.equals(STDIN_BY_BACKEND[backend.name], system.only_call().opts.stdin)
      system.restore()
    end)
  end
end)
