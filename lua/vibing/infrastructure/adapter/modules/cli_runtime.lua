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

--- How long `execute()` waits for a blocking call to finish.
M.INITIAL_RESPONSE_TIMEOUT_MS = 120000

--- A handle id unique across concurrent requests.
---
--- Hex, not decimal: LuaJIT's tostring() renders large hrtime doubles in scientific notation
--- ("2.64e+15"), and pre-tool-use.sh's char-sanitized VIBING_HANDLE_ID would then fail to match
--- this exact registry key.
---
--- @return string
function M.new_handle_id()
  return string.format("%016x_%x", vim.loop.hrtime(), math.random(100000))
end

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
]], pid)
  vim.system({ "sh", "-c", script }, {}, function() end)
  pcall(function()
    handle:kill(9)
  end)
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
--- @param handle_id string
--- @param message string
--- @param on_done fun(response: Vibing.Response)
local function report(handle_id, message, on_done)
  vim.schedule(function()
    on_done({ content = "", error = message, _handle_id = handle_id })
  end)
end

--- Report a failure that happened before the process existed, through `on_done`.
---
--- The command builders raise when their binary is missing, and `send_message.lua` does not wrap
--- `stream()` in pcall, so without this the chat buffer would show a raw Lua stack trace.
---
--- @param handle_id string
--- @param err any whatever pcall returned
--- @param on_done fun(response: Vibing.Response)
function M.report_build_failure(handle_id, err, on_done)
  report(handle_id, strip_source_location(err), on_done)
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
--- unregister the handle and clear the permission opts never runs. A permission entry left behind
--- is not inert: with a single entry in the table, the handler falls back to it for hook calls
--- carrying no matching handle_id.
---
--- Pass the adapter's own `wrapped_on_done`, which is what performs that cleanup.
---
--- @param handles table<string, table> the adapter's handle table
--- @param handle_id string
--- @param cmd string[] argv
--- @param sys_opts table vim.system options
--- @param on_exit function vim.system's exit callback
--- @param on_done fun(response: Vibing.Response) the adapter's wrapped_on_done
--- @return boolean started false when the failure has already been reported through on_done
function M.spawn(handles, handle_id, cmd, sys_opts, on_exit, on_done)
  local ok, handle_or_err = pcall(vim.system, cmd, sys_opts, on_exit)
  if not ok then
    report(handle_id, spawn_error_message(cmd, handle_or_err), on_done)
    return false
  end

  handles[handle_id] = stream_handle(handle_or_err, function()
    on_done({ content = "", error = "Cancelled", _handle_id = handle_id, _cancelled = true })
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

    local handle_id = self:stream(prompt, opts, function(chunk)
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
    if not done then
      self:cancel(handle_id)
      result.error = "Execution timeout"
    end
    return result
  end

  --- Cancel one in-flight request, or every one when `handle_id` is omitted.
  --- @param handle_id string?
  function Class:cancel(handle_id)
    if handle_id then
      local handle = self._handles[handle_id]
      if handle then
        self._handles[handle_id] = nil
        M.kill_tree(handle)
        if handle.on_cancel then
          handle.on_cancel()
        end
      end
      return
    end

    for id, handle in pairs(self._handles) do
      self._handles[id] = nil
      M.kill_tree(handle)
      if handle.on_cancel then
        handle.on_cancel()
      end
    end
  end

  --- @param feature string
  --- @return boolean
  function Class:supports(feature)
    return features[feature] or false
  end

  --- @param session_id string?
  --- @param handle_id string?
  function Class:set_session_id(session_id, handle_id)
    SessionManagerModule.set(self._session_manager, session_id, handle_id)
  end

  --- @param handle_id string?
  --- @return string?
  function Class:get_session_id(handle_id)
    return SessionManagerModule.get(self._session_manager, handle_id)
  end

  --- @param handle_id string
  function Class:cleanup_session(handle_id)
    SessionManagerModule.cleanup(self._session_manager, handle_id)
  end

  function Class:cleanup_stale_sessions()
    SessionManagerModule.cleanup_stale(self._session_manager, self._handles)
  end
end

return M
