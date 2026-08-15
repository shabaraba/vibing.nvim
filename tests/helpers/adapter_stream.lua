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

--- Created on first use and reused, so one spec file leaves one throwaway file behind.
local default_binary = nil

--- @class Vibing.Test.SystemCall
--- @field cmd string[] argv as passed to vim.system
--- @field opts table the options table (text/cwd/env/stdin/stdout/stderr)
--- @field on_exit function the exit callback vim.system was given
--- @field handle table the fake handle returned to the adapter

--- A path to a file that really exists, standing in for a resolved CLI binary.
---
--- It has to exist on disk, not just look like a path: the builders confirm a cached path with
--- `fs_stat` before reusing it (#593), so a made-up `/usr/local/bin/...` would be treated as a
--- binary that has gone and re-resolved on every call -- which is precisely what the caching
--- assertions are about.
---
--- Deliberately left non-executable: `grok_command_builder` skips its official-CLI sniff for a
--- path `executable()` rejects, which is the seam its own spec already relies on.
---
--- @param name string? a distinguishing suffix, so two calls can differ
--- @return string path
function M.fake_binary(name)
  local path = vim.fn.tempname() .. "-" .. (name or "cli")
  local fd = assert(io.open(path, "w"))
  fd:write("#!/bin/sh\n")
  fd:close()
  return path
end

--- Replace `vim.system`, `vim.fn.exepath` and the RPC port lookup for the duration of a test.
---
--- The port is stubbed rather than left to the real server: whether one is listening depends on
--- what else the test run started, and the env assertions need a fixed answer.
---
--- @param exe_path string? what exepath should report, defaults to a real throwaway file
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

  default_binary = default_binary or M.fake_binary("fake-cli")
  vim.fn.exepath = function()
    return exe_path or default_binary
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

  --- The call that launched the CLI, ignoring any side process the adapter fires alongside it.
  ---
  --- `stream()` is no longer always one spawn: a lightweight codex run also probes
  --- `codex doctor --json` to report the provider `--ignore-user-config` drops (#587). The CLI
  --- itself is the call whose stdout the adapter is streaming, which no side process has.
  --- @return Vibing.Test.SystemCall
  function state.cli_call()
    local streamed = vim.tbl_filter(function(call)
      return type(call.opts.stdout) == "function"
    end, state.calls)
    assert(#streamed == 1, "expected exactly one streamed vim.system call, got " .. #streamed)
    return streamed[1]
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
  -- Derived from the registry, not listed here: a hardcoded list silently skips a new backend,
  -- and then its "CLI missing" test passes against a stale cached path.
  for _, def in ipairs(require("vibing.core.constants.agents").list()) do
    local builder = require(def.command_builder_module)
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
