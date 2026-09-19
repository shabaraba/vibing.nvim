--- The parts of a CLI adapter that have nothing to do with which CLI is running.
---
--- Four adapters each wrote out their own `execute`, `cancel`, `supports` and the four
--- SessionManager delegations. Normalising the identifiers and diffing them, `supports` and the
--- session methods were identical in all four; `execute` and `cancel` had drifted into three
--- variants between them, which is the cost this module exists to stop paying (#515).
---
--- `stream()` stays in each adapter. Its differences are real -- which settings generator runs
--- before the build, how many arguments the command builder takes, whether a `chat_bufnr` or a
--- tool vocabulary gets registered, whether stderr needs filtering -- and there are more of those
--- than there are shared lines. The helpers here cover the pieces of it that genuinely repeat.
---
--- @module vibing.infrastructure.adapter.modules.cli_runtime

local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")

local M = {}

--- How long `execute()` waits for a blocking call to finish, and how long the oneshot transport
--- gives a resumed session to produce its first event.
---
--- **Keep this equal to `duplex_turn.FIRST_RESPONSE_TIMEOUT_MS`.** The two answer the same
--- question — how long to wait for the CLI's first byte — and changing one alone would leave the
--- two transports silently waiting different amounts of time for the same thing. Merging them
--- (and fixing this name, which is narrower than what it does) is #782.
M.INITIAL_RESPONSE_TIMEOUT_MS = 120000

--- @class Vibing.RequestIds The two identities one `stream()` call mints.
--- @field process_id string The OS process. Keys `adapter._processes`, the SessionManager, and the
---   `VIBING_PROCESS_ID` the shell hooks are handed. The only thing `cancel()` accepts.
--- @field turn_id string The request/response exchange. Keys both diff baselines, the response
---   staleness check and the registry entry. `stream()` returns it first, because it is what the
---   chat buffer means by "the request I am waiting for".

--- Kill a spawned CLI along with the descendants holding its stdout pipe open.
---
--- Killing only the parent is not enough: the CLI's tool execution spawns shells (and MCP
--- servers) that inherit the pipe, so `vim.system()`'s exit handler -- which waits for stdout to
--- close -- never fires. A single `pkill -P` is not enough either when a backend leaves the pipe
--- in a grandchild. Kill descendants deepest-first, then the process handle itself.
---
--- The descendant walk is fire-and-forget rather than `vim.fn.system`, because cancel can be
--- reached from a `vim.schedule` callback and blocking Neovim's main loop on it is avoidable.
---
--- @param handle table? a vim.system handle
function M.kill_tree(handle)
  if not handle then
    return
  end

  local pid = handle.pid
  if not pid or pid <= 0 then
    return
  end

  local script = string.format([[
kill_descendants() {
  parent="$1"
  for child in $(pgrep -P "$parent" 2>/dev/null); do
    kill_descendants "$child"
    kill -9 "$child" 2>/dev/null
  done
}
kill_descendants %d
kill -9 %d 2>/dev/null
]], pid, pid)
  vim.system({ "sh", "-c", script }, {}, function()
    pcall(function()
      handle:kill(9)
    end)
  end)
end

--- Run the stream completion callback without letting one failed callback stop later cancels.
--- @param handle table
local function complete_cancel(handle)
  if not handle.on_cancel then
    return
  end
  local ok, err = pcall(handle.on_cancel)
  if not ok then
    vim.schedule(function()
      vim.notify("[vibing] Cancel cleanup failed: " .. tostring(err), vim.log.levels.WARN)
    end)
  end
end

--- Wrap vim.system's handle with the extra metadata cancel() needs while preserving the small
--- handle surface the rest of the adapters use (`pid` and `:kill()`).
--- @param process table vim.system handle
--- @param on_cancel fun()
--- @return table
local function stream_handle(process, on_cancel)
  return {
    process = process,
    pid = process.pid,
    kill = function(_, signal)
      process:kill(signal)
    end,
    on_cancel = on_cancel,
  }
end

--- An error message with its `file.lua:123:` prefix removed.
---
--- The chat buffer should show a message, not a source location.
---
--- @param err any whatever pcall returned
--- @return string
local function strip_source_location(err)
  return type(err) == "string" and (err:gsub("^.*:%d+:%s*", "")) or tostring(err)
end

--- Hand a failure that happened before the process existed back to the caller.
---
--- Both ids are attached even though no process was ever started: `_turn_id` is what the chat
--- buffer's staleness check compares, and `_process_id` is what the session read-back uses, so a
--- response missing either one is indistinguishable from a response belonging to someone else.
---
--- @param ids Vibing.RequestIds
--- @param message string
--- @param on_done fun(response: Vibing.Response)
local function report(ids, message, on_done)
  vim.schedule(function()
    on_done({ content = "", error = message, _turn_id = ids.turn_id, _process_id = ids.process_id })
  end)
end

--- Report a failure that happened before the process existed, through `on_done`.
---
--- The command builders raise when their binary is missing, and `send_message.lua` does not wrap
--- `stream()` in pcall, so without this the chat buffer would show a raw Lua stack trace.
---
--- @param ids Vibing.RequestIds
--- @param err any whatever pcall returned
--- @param on_done fun(response: Vibing.Response)
function M.report_build_failure(ids, err, on_done)
  report(ids, strip_source_location(err), on_done)
end

--- What to tell the user when `vim.system` itself raised instead of starting the CLI.
---
--- The builder's own "not found in PATH" check cannot cover the missing-binary case: it resolved a
--- path, and the binary went away between that answer and the spawn. libuv reports that as a bare
--- `ENOENT: no such file or directory (cmd): '<path>'`, which reads as an internal error rather
--- than a CLI to reinstall -- so that one case is named, and every other spawn failure is passed
--- through with its own text.
---
--- **The `(cmd)` marker is what decides, not `ENOENT`.** A cwd that no longer exists raises ENOENT
--- too, as `(cwd)`, and that is not a hypothetical: a chat's `working_dir` frontmatter outlives
--- `git worktree remove`, and `Git.resolve_working_dir` does not check the directory is still
--- there. Keying on the error code alone told those users to reinstall a CLI that was fine.
---
--- @param cmd string[] the argv that failed to spawn
--- @param err any whatever pcall returned
--- @return string
local function spawn_error_message(cmd, err)
  local message = strip_source_location(err)

  if message:find("ENOENT", 1, true) and message:find("(cmd)", 1, true) then
    return string.format("%s could not be started: it is no longer there. Reinstall the CLI.", cmd[1])
  end

  return string.format("Failed to spawn %s: %s", cmd[1], message)
end

--- Start the CLI, or report why it could not start.
---
--- `vim.system` raises synchronously when the spawn itself fails -- a binary that went missing
--- between the builder resolving it and now, an invalid cwd -- before any process exists. Left
--- unguarded that reaches the chat as a Lua stack trace, and the exit handler that would normally
--- unregister the stream and clear the permission opts never runs. A leaked permission entry is no
--- longer reachable by a hook naming an unmatched process — `rpc/hook_scope.lua` returns nil there
--- rather than falling back — but it still grows the table and still answers for a hook that names
--- no process at all while it is the only entry.
---
--- Pass the adapter's own `wrapped_on_done`, which is what performs that cleanup.
---
--- @param processes table<string, table> the adapter's process table, keyed by process id
--- @param ids Vibing.RequestIds
--- @param cmd string[] argv
--- @param sys_opts table vim.system options
--- @param on_exit function vim.system's exit callback
--- @param on_done fun(response: Vibing.Response) the adapter's wrapped_on_done
--- @return boolean started false when the failure has already been reported through on_done
function M.spawn(processes, ids, cmd, sys_opts, on_exit, on_done)
  local ok, handle_or_err = pcall(vim.system, cmd, sys_opts, on_exit)
  if not ok then
    report(ids, spawn_error_message(cmd, handle_or_err), on_done)
    return false
  end

  processes[ids.process_id] = stream_handle(handle_or_err, function()
    on_done({
      content = "",
      error = "Cancelled",
      _turn_id = ids.turn_id,
      _process_id = ids.process_id,
      _cancelled = true,
    })
  end)
  return true
end

--- Install every method whose implementation does not depend on the backend.
---
--- Defines `execute`, `cancel`, `supports` and the four session delegations on `Class`. The
--- adapter is left with `new()` and `stream()`.
---
--- @param Class table the adapter class
--- @param features table<string, boolean> what `supports()` should answer
function M.install(Class, features)
  --- Run a prompt to completion and return the response, for callers that cannot stream.
  --- @param prompt string
  --- @param opts Vibing.AdapterOpts
  --- @return Vibing.Response
  function Class:execute(prompt, opts)
    opts = opts or {}
    local result = { content = "" }
    local done = false

    local _, process_id = self:stream(prompt, opts, function(chunk)
      result.content = result.content .. chunk
    end, function(response)
      if response.error then
        result.error = response.error
      end
      done = true
    end)

    vim.wait(M.INITIAL_RESPONSE_TIMEOUT_MS, function()
      return done
    end, 100)

    -- Cancelling on timeout is what keeps a hung CLI from outliving the call that started it.
    -- Three of the four adapters used to return here and leave the process running.
    --
    -- The `process_id` guard is not defensive noise: `cancel(nil)` means "every process this
    -- adapter owns", and one adapter instance is shared between a chat's stream and the
    -- lightweight `execute()` calls — so a `stream()` that returned only its turn id would turn
    -- one utility call's timeout into a kill of every live chat on that backend.
    if not done then
      if process_id then
        self:cancel(process_id)
      end
      result.error = "Execution timeout"
    end
    return result
  end

  --- Cancel one CLI process, or every one this adapter owns when `process_id` is omitted.
  ---
  --- Named by the process, not the turn: killing is something you do to a process, and under a
  --- resident process (#774) the two are no longer the same choice — a turn will be stopped with an
  --- interrupt while the process stays alive.
  --- @param process_id string?
  function Class:cancel(process_id)
    if process_id then
      local handle = self._processes[process_id]
      if handle then
        self._processes[process_id] = nil
        M.kill_tree(handle)
        complete_cancel(handle)
      end
      return
    end

    for id, handle in pairs(self._processes) do
      self._processes[id] = nil
      M.kill_tree(handle)
      complete_cancel(handle)
    end
  end

  --- Stop the turn without stopping the process, where the process can serve the next one.
  ---
  --- Kept apart from `cancel` rather than folded into it, because two callers want opposite things
  --- from the same word. `permission.lua`'s `cancel_and_deny` relies on `cancel` running
  --- `wrapped_on_done` synchronously and on the process being gone afterwards (that is what makes
  --- the approval's retry message a *new* turn); the user pressing cancel wants the conversation's
  --- process still there for the next message. Only the second one is routed here.
  ---
  --- Stopping is still guaranteed either way: the resident path sends an interrupt and falls back
  --- to this same `cancel` if the CLI has not stopped within `INTERRUPT_GRACE_MS`.
  --- @param process_id string?
  function Class:stop_turn(process_id)
    local Routing = require("vibing.infrastructure.adapter.modules.duplex_routing")
    if process_id and Routing.stop_turn(self, process_id) then
      return
    end
    self:cancel(process_id)
  end

  --- Release the resident process a chat was holding, because the chat is gone.
  ---
  --- The symmetric half of `stop_turn`: that one says "stop this turn, keep the process", this one
  --- says "the chat is gone, so is its process". Both exist so `presentation/` can say what it
  --- means through the adapter interface instead of reaching into one transport's own pool.
  --- @param chat_bufnr number?
  function Class:release_chat(chat_bufnr)
    require("vibing.infrastructure.adapter.modules.duplex_pool").stop(chat_bufnr)
  end

  --- @param feature string
  --- @return boolean
  function Class:supports(feature)
    return features[feature] or false
  end

  --- @param session_id string?
  --- @param process_id string?
  function Class:set_session_id(session_id, process_id)
    SessionManagerModule.set(self._session_manager, session_id, process_id)
  end

  --- @param process_id string?
  --- @return string?
  function Class:get_session_id(process_id)
    return SessionManagerModule.get(self._session_manager, process_id)
  end

  --- @param process_id string
  function Class:cleanup_session(process_id)
    SessionManagerModule.cleanup(self._session_manager, process_id)
  end

  function Class:cleanup_stale_sessions()
    SessionManagerModule.cleanup_stale(self._session_manager, self._processes)
  end
end

return M
