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

--- Kill a spawned CLI along with the children holding its stdout pipe open.
---
--- Killing only the parent is not enough: the CLI's tool execution spawns shells (and MCP
--- servers) that inherit the pipe, so `vim.system()`'s exit handler -- which waits for stdout to
--- close -- never fires. The animation never stops and the chat UI stays frozen.
---
--- The pkill is fire-and-forget rather than `vim.fn.system`, because cancel can be reached from a
--- `vim.schedule` callback and blocking Neovim's main loop on it is avoidable.
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

  vim.system({ "sh", "-c", string.format("pkill -9 -P %d 2>/dev/null", pid) }, {}, function() end)
  pcall(function()
    handle:kill(9)
  end)
end

--- Report a failure that happened before the process existed, through `on_done`.
---
--- The command builders raise when their binary is missing, and `send_message.lua` does not wrap
--- `stream()` in pcall, so without this the chat buffer would show a raw Lua stack trace. The
--- `file:line` prefix is stripped for the same reason: the chat should show a message, not a
--- source location.
---
--- @param handle_id string
--- @param err any whatever pcall returned
--- @param on_done fun(response: Vibing.Response)
function M.report_build_failure(handle_id, err, on_done)
  local message = type(err) == "string" and err:gsub("^.*:%d+:%s*", "") or tostring(err)
  vim.schedule(function()
    on_done({ content = "", error = message, _handle_id = handle_id })
  end)
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
      result.error = result.error or "Execution timeout"
    end
    return result
  end

  --- Cancel one in-flight request, or every one when `handle_id` is omitted.
  --- @param handle_id string?
  function Class:cancel(handle_id)
    if handle_id then
      local handle = self._handles[handle_id]
      if handle then
        M.kill_tree(handle)
        self._handles[handle_id] = nil
      end
      return
    end

    for id, handle in pairs(self._handles) do
      M.kill_tree(handle)
      self._handles[id] = nil
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
