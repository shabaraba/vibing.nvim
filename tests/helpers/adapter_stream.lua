--- Test seam for adapter `stream()`.
---
--- `stream()` is the one part of an adapter that was never unit tested, because it spawns a real
--- process. Everything worth asserting about it, though, happens before the process exists: what
--- goes into `vim.system`'s options, who gets registered, which timer is armed. Stubbing
--- `vim.system` exposes all of that without a CLI on the machine.
---
--- Shared across the three adapters on purpose. Per-adapter mocks would drift, and the point of
--- these tests is that the three behave the same.
--- @module tests.helpers.adapter_stream

local M = {}

--- @class Vibing.Test.SystemCall
--- @field cmd string[] argv as passed to vim.system
--- @field opts table the options table (text/cwd/env/stdin/stdout/stderr)
--- @field on_exit function the exit callback vim.system was given
--- @field handle table the fake handle returned to the adapter

--- Replace `vim.system`, `vim.fn.exepath` and the RPC port lookup for the duration of a test.
---
--- The port is stubbed rather than left to the real server: whether one is listening depends on
--- what else the test run started, and the env assertions need a fixed answer.
---
--- @param exe_path string? what exepath should report, defaults to a plausible binary path
--- @param rpc_port number? what the RPC server should report, defaults to 9999
--- @return table state `{ calls = Vibing.Test.SystemCall[], restore = fun() }`
function M.stub_system(exe_path, rpc_port)
  local original_system = vim.system
  local original_exepath = vim.fn.exepath

  local rpc_server = require("vibing.infrastructure.rpc.server")
  local original_get_port = rpc_server.get_port
  rpc_server.get_port = function()
    return rpc_port or 9999
  end

  local state = { calls = {} }

  vim.fn.exepath = function()
    return exe_path or "/usr/local/bin/fake-cli"
  end

  vim.system = function(cmd, opts, on_exit)
    local handle = { pid = 4242, kill = function() end }
    table.insert(state.calls, { cmd = cmd, opts = opts, on_exit = on_exit, handle = handle })
    return handle
  end

  function state.restore()
    vim.system = original_system
    vim.fn.exepath = original_exepath
    rpc_server.get_port = original_get_port
  end

  --- The single call, asserting there was exactly one.
  --- @return Vibing.Test.SystemCall
  function state.only_call()
    assert(#state.calls == 1, "expected exactly one vim.system call, got " .. #state.calls)
    return state.calls[1]
  end

  return state
end

--- Drive an adapter's `stream()` and collect what it produced.
---
--- @param adapter table an instantiated adapter
--- @param opts table? adapter opts, merged over a minimal working set
--- @return table result `{ handle_id, done_responses = table[], call = Vibing.Test.SystemCall }`
function M.run_stream(adapter, opts)
  local done_responses = {}

  local handle_id = adapter:stream(
    "hello",
    vim.tbl_extend("force", { permissions_allow = {} }, opts or {}),
    function() end,
    function(response)
      table.insert(done_responses, response)
    end
  )

  return { handle_id = handle_id, done_responses = done_responses }
end

--- Forget every builder's resolved binary path.
---
--- The caches are module-level and therefore process-wide: once one spec has resolved a path, a
--- later spec stubbing exepath to "" would otherwise never reach the missing-CLI branch.
function M.reset_path_caches()
  for _, module in ipairs({
    "vibing.infrastructure.adapter.modules.cli_command_builder",
    "vibing.infrastructure.adapter.modules.codex_command_builder",
    "vibing.infrastructure.adapter.modules.copilot_command_builder",
  }) do
    local builder = require(module)
    if builder._reset_path_cache then
      builder._reset_path_cache()
    end
  end
end

--- Every adapter under test, so a new backend joins these tests by adding one line.
--- @return table[] `{ name, module }`
function M.adapters()
  local Agents = require("vibing.core.constants.agents")
  local out = {}
  for _, def in ipairs(Agents.list()) do
    table.insert(out, { name = def.id, module = require(def.adapter_module) })
  end
  return out
end

return M
