--- Test seam for adapter `stream()`.
---
--- `stream()` is the one part of an adapter that was never unit tested, because it spawns a real
--- process. Everything worth asserting about it, though, happens before the process exists: what
--- goes into `vim.system`'s options, who gets registered, which timer is armed. Stubbing
--- `vim.system` exposes all of that without a CLI on the machine.
---
--- Shared across every adapter on purpose. Per-adapter mocks would drift, and the point of these
--- tests is that they behave the same.
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

--- @class Vibing.Test.JobCall
--- @field argv string[] argv as passed to jobstart
--- @field opts table the options table (cwd/env/clear_env/on_stdout/on_stderr/on_exit)
--- @field job_id number the channel the adapter was handed
--- @field stdin string[] every chunk `chansend` wrote to it
--- @field stopped boolean whether `jobstop` was called

--- Replace the `jobstart` family for the duration of a test.
---
--- The duplex transport spawns with `jobstart` rather than `vim.system`, because only a job hands
--- back a writable channel (`duplex_process.lua`). `vim.system` is stubbed to a no-op alongside it:
--- stopping a resident process goes through `cli_runtime.kill_tree`, which shells out to a real
--- `kill -9` against whatever pid it was handed, and a fake pid in a test is a real pid on the
--- machine running it.
---
--- @return table state `{ calls, restore, only_call, emit, exit }`
function M.stub_jobstart()
  local originals = {
    jobstart = vim.fn.jobstart,
    jobpid = vim.fn.jobpid,
    jobstop = vim.fn.jobstop,
    chansend = vim.fn.chansend,
    system = vim.system,
  }

  local state = { calls = {}, pending_exits = {} }
  local next_job_id = 0

  vim.fn.jobstart = function(argv, opts)
    next_job_id = next_job_id + 1
    local call = { argv = argv, opts = opts, job_id = next_job_id, stdin = {}, stopped = false }
    table.insert(state.calls, call)
    return call.job_id
  end
  vim.fn.jobpid = function(job_id)
    return 900000 + job_id
  end
  -- Stopping a job does **not** fire `on_exit` here, and that is the point rather than a
  -- simplification. Neovim flushes the job's streams first, so the real callback always lands a
  -- tick or more later — by which time the pool may already have installed a replacement process
  -- under the same chat. A stub that fired `on_exit` inline would make that ordering untestable,
  -- and a stub that never fires it at all hides the whole class. `state.flush_exits()` is the
  -- explicit "later" a spec asks for.
  vim.fn.jobstop = function(job_id)
    for _, call in ipairs(state.calls) do
      if call.job_id == job_id and not call.stopped then
        call.stopped = true
        table.insert(state.pending_exits, call)
      end
    end
    return 1
  end
  vim.fn.chansend = function(job_id, data)
    for _, call in ipairs(state.calls) do
      if call.job_id == job_id then
        table.insert(call.stdin, data)
      end
    end
    return #data
  end
  -- `kill_tree` shells out to walk descendants and only touches its own handle from that call's
  -- completion callback, so a stub that never calls back makes every kill a silent no-op.
  vim.system = function(_, _, on_exit)
    if on_exit then
      on_exit({ code = 0, stdout = "", stderr = "" })
    end
    return { pid = 0, kill = function() end, wait = function() return { code = 0 } end }
  end

  function state.restore()
    for name, fn in pairs(originals) do
      if name == "system" then
        vim.system = fn
      else
        vim.fn[name] = fn
      end
    end
  end

  --- @return Vibing.Test.JobCall
  function state.only_call()
    assert(#state.calls == 1, "expected exactly one jobstart call, got " .. #state.calls)
    return state.calls[1]
  end

  --- Hand complete stdout lines to a job, the way Neovim does: the last element of a batch is the
  --- partial line carried forward, so a batch of whole lines ends with an empty string.
  --- @param call Vibing.Test.JobCall
  --- @param lines string[]
  function state.emit(call, lines)
    local batch = vim.list_extend(vim.deepcopy(lines), { "" })
    call.opts.on_stdout(call.job_id, batch, "stdout")
  end

  --- @param call Vibing.Test.JobCall
  --- @param code number?
  function state.exit(call, code)
    call.opts.on_exit(call.job_id, code or 0, "exit")
  end

  --- Deliver the `on_exit` of every job that has been stopped but not yet reaped.
  ---
  --- This is the tick Neovim takes between `jobstop` and the callback. A spec that stops a process
  --- and then carries on without calling this is testing a world where killing something is
  --- instantaneous, which is the world the pool's identity bug survived in.
  --- @param code number?
  function state.flush_exits(code)
    local pending = state.pending_exits
    state.pending_exits = {}
    for _, call in ipairs(pending) do
      call.opts.on_exit(call.job_id, code or 0, "exit")
    end
  end

  --- What the adapter wrote to a job's stdin, decoded.
  --- @param call Vibing.Test.JobCall
  --- @return table[]
  function state.sent(call)
    return vim.tbl_map(function(chunk)
      return vim.json.decode(chunk)
    end, call.stdin)
  end

  return state
end

--- Drive an adapter's `stream()` and collect what it produced.
---
--- @param adapter table an instantiated adapter
--- @param opts table? adapter opts, merged over a minimal working set
--- @return table result `{ turn_id, process_id, done_responses = table[] }`
function M.run_stream(adapter, opts)
  local done_responses = {}

  -- Both ids, because they are not the same value: `turn_id` is the turn a response belongs to
  -- and `process_id` is what `cancel()` accepts. A spec that uses one where it means the other now
  -- fails rather than passing by coincidence (#774).
  local turn_id, process_id = adapter:stream(
    "hello",
    vim.tbl_extend("force", { permissions_allow = {} }, opts or {}),
    function() end,
    function(response)
      table.insert(done_responses, response)
    end
  )

  return { turn_id = turn_id, process_id = process_id, done_responses = done_responses }
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
