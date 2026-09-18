--- One resident CLI process, serving many turns over an open stdin (#777).
---
--- `vim.system()` cannot be used here. It hands back no writable channel, so the only spawn
--- primitive that can carry a second turn to an already-running CLI is `jobstart` + `chansend` —
--- the shape `completion/cli_command_list.lua` already uses to ask the CLI a `control_request`
--- before any turn starts. The line assembly, the `request_id` correlation and the idempotent
--- finish latch below are that module's, generalised to a process that answers more than once.
---
--- The reversal worth stating: under `vim.system` the exit callback does not fire until stdout
--- closes, which is why `cli_runtime.kill_tree` has to walk descendants at all. Here the process is
--- *meant* to outlive its stdout being quiet, so exit is no longer a completion signal for anything
--- but the process itself. A turn ends on the `result` event (`decoders/claude_stream_json.lua`).
--- @module vibing.infrastructure.adapter.modules.duplex_process

local M = {}

--- @class Vibing.DuplexProcess
--- @field process_id string The `VIBING_PROCESS_ID` the child was spawned with; also its registry key.
--- @field job_id number The `jobstart` channel, which is what `chansend` writes to.
--- @field pid number
--- @field argv_key string The argv this process was started with, minus the resume pair. A turn
---   whose argv no longer matches this cannot be served here (`duplex_pool.lua`).
--- @field decoder_state table Parse state that belongs to the *process*, not to any one turn: the
---   session id the decoder has already reported. A fresh table per turn would re-announce the
---   session on the first line of every turn.
--- @field on_line fun(line: string, record: Vibing.DuplexProcess) Where a complete stdout line goes.
---   The record is passed back rather than captured, because a process that has already been
---   replaced goes on flushing what Neovim buffered for it: the router compares identity to decide
---   whether those bytes belong to the chat's current process (`duplex_routing.lua`).
--- @field on_stderr fun(text: string, record: Vibing.DuplexProcess) Same, for stderr.
--- @field on_exit fun(code: number)
--- @field stopping boolean Set before a deliberate kill so `on_exit` can tell it from a crash.

--- Interrupts are correlated by id like every other control request; the CLI echoes it back in the
--- `control_response`. Nothing waits on that response today (the turn ends on `result`), but a
--- request with no id is one the CLI is free to reject.
local INTERRUPT_REQUEST_PREFIX = "vibing-interrupt-"

--- @param record Vibing.DuplexProcess
--- @param data string[] one `on_stdout` batch
local function absorb(record, data)
  -- data[1] continues the partial line left by the previous callback; a `result` line carrying a
  -- long tool transcript always arrives split across several batches.
  --
  -- The fragments of that partial line are held as a list and joined only when its newline finally
  -- arrives. Appending each batch onto one growing string instead would re-copy everything received
  -- so far on every callback -- quadratic in the length of exactly the longest line there is.
  local fragments = record._pending
  if #data == 1 then
    table.insert(fragments, data[1])
    return
  end

  table.insert(fragments, data[1] or "")
  local line = table.concat(fragments)
  if line ~= "" then
    -- The record goes with the line: a process that has already been replaced can still be
    -- flushing output, and the router has to be able to tell that this is not the process its
    -- chat is currently using (`duplex_routing.lua`).
    record.on_line(line, record)
  end

  -- Everything between the first and last element is a complete line of its own; the last is the
  -- partial carried forward.
  for i = 2, #data - 1 do
    if data[i] ~= "" then
      record.on_line(data[i], record)
    end
  end
  record._pending = { data[#data] }
end

--- @class Vibing.DuplexSpawnOpts
--- @field process_id string
--- @field argv string[]
--- @field argv_key string
--- @field cwd string
--- @field env table<string, string>
--- @field on_line fun(line: string)
--- @field on_stderr fun(text: string)
--- @field on_exit fun(code: number)

--- Start a resident CLI.
--- @param opts Vibing.DuplexSpawnOpts
--- @return Vibing.DuplexProcess|nil record
--- @return string|nil error why it could not start
function M.start(opts)
  --- @type Vibing.DuplexProcess
  local record = {
    process_id = opts.process_id,
    argv_key = opts.argv_key,
    decoder_state = {},
    on_line = opts.on_line,
    on_stderr = opts.on_stderr,
    on_exit = opts.on_exit,
    stopping = false,
    _pending = { "" },
  }

  local ok, job_id = pcall(vim.fn.jobstart, opts.argv, {
    cwd = opts.cwd,
    env = opts.env,
    clear_env = true,
    on_stdout = function(_, data)
      if type(data) == "table" and #data > 0 then
        absorb(record, data)
      end
    end,
    on_stderr = function(_, data)
      if type(data) == "table" and #data > 0 then
        local text = table.concat(data, "\n")
        if text ~= "" then
          record.on_stderr(text, record)
        end
      end
    end,
    on_exit = function(_, code)
      record.job_id = nil
      record.on_exit(code)
    end,
  })

  if not ok then
    return nil, tostring(job_id)
  end
  if type(job_id) ~= "number" or job_id <= 0 then
    return nil, string.format("jobstart returned %s for %s", tostring(job_id), opts.argv[1])
  end

  record.job_id = job_id
  record.pid = vim.fn.jobpid(job_id)
  return record, nil
end

--- @param record Vibing.DuplexProcess
--- @return boolean
function M.is_alive(record)
  return record ~= nil and record.job_id ~= nil
end

--- @param record Vibing.DuplexProcess
--- @param payload table
--- @return boolean sent
local function write(record, payload)
  if not M.is_alive(record) then
    return false
  end
  -- The byte count decides, not `pcall`. A job that has been killed but whose `on_exit` has not
  -- yet run still has a valid channel id — `job_id` is cleared only there — so `is_alive` says yes
  -- and `chansend` quietly returns 0. Reading that as success is how a turn gets bound to a dying
  -- process and then waits out the whole first-response watchdog with nothing to show for it.
  local ok, written = pcall(vim.fn.chansend, record.job_id, vim.json.encode(payload) .. "\n")
  return ok and type(written) == "number" and written > 0
end

--- Begin a turn by handing the CLI a user message on stdin.
---
--- `--input-format stream-json` takes the same envelope the CLI emits, so the prompt travels as a
--- plain `user` message rather than as an argv argument. The content is a string rather than a
--- one-element block list: both are accepted, and the string form is what the CLI's own replay
--- emits back.
--- @param record Vibing.DuplexProcess
--- @param prompt string
--- @return boolean sent
function M.send_prompt(record, prompt)
  return write(record, { type = "user", message = { role = "user", content = prompt } })
end

--- Stop the turn without stopping the process.
---
--- The CLI answers with `control_response { still_queued = [] }` and then a `result` of subtype
--- `error_during_execution`; the process stays alive and serves the next turn normally. That
--- `result` is what ends the turn here, so nothing waits on the control response.
--- @param record Vibing.DuplexProcess
--- @param seq number a per-process counter, so two interrupts never share a request id
--- @return boolean sent
function M.interrupt(record, seq)
  return write(record, {
    type = "control_request",
    request_id = INTERRUPT_REQUEST_PREFIX .. tostring(seq),
    request = { subtype = "interrupt" },
  })
end

--- Stop the process, and everything holding its pipes open.
---
--- `jobstop` alone is not enough for the same reason `vim.system():kill()` was not: Neovim flushes
--- the job's streams before firing `on_exit`, and the CLI's tool execution leaves shells and MCP
--- servers holding those pipes. So this goes through the one descendant walk there is
--- (`cli_runtime.kill_tree`), handing it the `{ pid, kill }` surface that walk documents.
--- @param record Vibing.DuplexProcess
function M.stop(record)
  if not M.is_alive(record) then
    return
  end
  local job_id = record.job_id
  require("vibing.infrastructure.adapter.modules.cli_runtime").kill_tree({
    pid = record.pid,
    kill = function()
      pcall(vim.fn.jobstop, job_id)
    end,
  })
end

return M
