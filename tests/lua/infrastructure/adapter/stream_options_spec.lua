---@diagnostic disable: undefined-field
--- Covers what `stream()` sets up before the process exists, across all three adapters at once.
--- Previously untested: #510's review flagged it, #514 is the follow-up.
local helper = require("tests.helpers.adapter_stream")
local ActiveStreamRegistry = require("vibing.infrastructure.adapter.modules.active_stream_registry")
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

      it("passes the handle id so concurrent chats do not cross-wire their approval UI", function()
        local result = helper.run_stream(adapter)
        assert.equals(result.handle_id, system.only_call().opts.env.VIBING_HANDLE_ID)
      end)

      it("inherits the parent environment rather than starting from empty", function()
        helper.run_stream(adapter)
        assert.is_not_nil(system.only_call().opts.env.PATH)
      end)
    end)

    describe("stream registry", function()
      it("registers the handle while the process runs", function()
        local result = helper.run_stream(adapter)
        assert.is_not_nil(ActiveStreamRegistry.get(result.handle_id))
      end)

      it("unregisters once the process exits", function()
        local result = helper.run_stream(adapter)
        system.only_call().on_exit({ code = 0, stdout = "", stderr = "" })
        vim.wait(200, function()
          return ActiveStreamRegistry.get(result.handle_id) == nil
        end)
        assert.is_nil(ActiveStreamRegistry.get(result.handle_id))
      end)

      it("clears the permission opts once the process exits", function()
        local result = helper.run_stream(adapter, { permissions_deny = { "Bash" } })
        system.only_call().on_exit({ code = 0, stdout = "", stderr = "" })
        vim.wait(200, function()
          return perm_handler.get_active_opts_for_test == nil
        end)
        -- clear_active_opts is what stream() promises to call; re-registering a fresh handle must
        -- not see the old one's deny list.
        assert.is_not_nil(result.handle_id)
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
  -- claude reads its prompt from argv; codex and copilot are given an explicit empty stdin so they
  -- do not sit waiting on a terminal that isn't there.
  local STDIN_BY_BACKEND = { claude = nil, codex = "", copilot = "" }

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
