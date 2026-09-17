--- The duplex tail of `cli_adapter.stream()`: get a resident process, put a turn on it (#777).
---
--- The oneshot tail spawns a process and waits for it to exit. This one takes a process from
--- `duplex_pool` — spawning only when there is none it can honestly reuse — and writes the prompt
--- to its stdin.
---
--- What splits per turn and what does not is the whole design:
---
--- * **Per turn** — the event context (`output`, `errorOutput`, `tokenUsage`, `cliInfo`,
---   `resultErrors`), the `TurnRegistry` entry, and `permission.set_active_opts`. All three were
---   already per turn; a resident process is simply the first transport where that is observable.
--- * **Per process** — the decoder's own parse state (which session it has already announced) and
---   the `ProcessRegistry` entry. A fresh decoder state per turn would re-announce the session on
---   every turn's first line.
---
--- The turn's own lifetime is `duplex_turn.lua`; where a process's stdout, stderr, death and kill
--- switch are wired is `duplex_routing.lua`.
--- @module vibing.infrastructure.adapter.modules.duplex_stream

local DuplexProcess = require("vibing.infrastructure.adapter.modules.duplex_process")
local DuplexTurn = require("vibing.infrastructure.adapter.modules.duplex_turn")
local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
local RequestBuilder = require("vibing.infrastructure.adapter.modules.request_builder")
local Routing = require("vibing.infrastructure.adapter.modules.duplex_routing")

local M = {}

--- @class Vibing.DuplexRunParams
--- @field adapter table the adapter instance, so `_processes` can carry a cancellable handle
--- @field descriptor Vibing.BackendDescriptor
--- @field config Vibing.Config
--- @field ids Vibing.RequestIds the turn id is final; the process id is a candidate, used only
---   when this turn has to spawn
--- @field prompt string the raw prompt, before the pieces `request_builder` prepends
--- @field opts Vibing.AdapterOpts
--- @field hook_arg any
--- @field cwd string
--- @field env table<string, string>
--- @field argv string[] the argv for this turn, with `--resume` when there is a session to resume
--- @field event_context table
--- @field finish fun(response: Vibing.Response) the shared completion tail in `cli_adapter`
--- @field tag string

--- The argv a live process must match to be reused: this turn's, built with no session id.
---
--- Building it twice is the point. `--resume` is absent on turn 1 and present on turn 2, so an
--- as-written argv differs by construction on every chat's second turn — every chat would restart
--- its process every time, and the feature would buy nothing while looking correct.
--- @param params Vibing.DuplexRunParams
--- @return string|nil key, string|nil error
local function reuse_key(params)
  local ok, cmd = pcall(params.descriptor.build, params.prompt, params.opts, nil, params.config, params.hook_arg)
  if not ok then
    return nil, tostring(cmd)
  end
  return table.concat(cmd, "\30"), nil
end

--- Start a turn on a resident process.
--- @param params Vibing.DuplexRunParams
--- @return string turn_id
--- @return string process_id
function M.run(params)
  local ids = params.ids
  local chat_key = params.opts.chat_bufnr
  local descriptor = params.descriptor

  local function fail(message)
    vim.schedule(function()
      params.finish({ content = "", error = message, _turn_id = ids.turn_id, _process_id = ids.process_id })
    end)
    return ids.turn_id, ids.process_id
  end

  local argv_key, key_err = reuse_key(params)
  if not argv_key then
    return fail(key_err)
  end

  local record, err = Pool.acquire(chat_key, {
    process_id = ids.process_id,
    argv = params.argv,
    argv_key = argv_key,
    cwd = params.cwd,
    env = params.env,
    process_entry = {
      process_id = ids.process_id,
      chat_bufnr = descriptor.register_chat_bufnr and chat_key or nil,
      session_id = params.opts._session_id,
      adapter = params.adapter,
    },
    on_line = Routing.line_router(chat_key, descriptor),
    on_stderr = Routing.stderr_router(chat_key),
    on_exit = Routing.exit_handler(params.adapter),
  })
  if not record then
    return fail(err)
  end

  -- A reused process keeps the id it was spawned with, because that is the one its child
  -- environment (and therefore every hook it fires) already names.
  ids.process_id = record.process_id
  params.event_context.processId = record.process_id
  params.event_context._decoder_state = record.decoder_state
  Routing.idle_context(record, params.event_context.sessionManager)
  params.adapter._processes[record.process_id] = Routing.cancellable_handle(record, chat_key)

  local complete = DuplexTurn.open(params, record, chat_key)

  local prompt =
    RequestBuilder.prompt_text(descriptor.request, params.prompt, params.opts, params.opts._session_id, params.config)
  if not DuplexProcess.send_prompt(record, prompt or params.prompt) then
    -- Reported before the kill, for the reason spelled out in `duplex_turn`'s watchdog: `Pool.stop`
    -- completes this turn as "Cancelled" on its way out, and `complete` is idempotent, so killing
    -- first would replace this message with one that says nothing about what went wrong.
    complete({
      content = "",
      error = "Could not write the prompt to the resident CLI process.",
      _turn_id = ids.turn_id,
      _process_id = record.process_id,
    })
    Pool.stop(chat_key)
  end

  return ids.turn_id, record.process_id
end

--- How long an interrupt has to actually stop the turn before the process is killed instead.
---
--- The contract the user sees is "if I say stop, it stops". Keeping the process alive is an
--- optimisation underneath that contract, not a replacement for it: `chansend` succeeding means the
--- bytes were written, never that the CLI acted on them, and a CLI wedged inside a tool call will
--- not act on them at all. Without this, `<C-c>` — which has always killed — would silently become
--- a request the process is free to ignore.
---
--- Measured against claude 2.1.236 mid-generation, the turn ended **16ms** after the interrupt was
--- written. This is ~300x that, on purpose: 16ms is the responsive case, and the case this exists
--- for is the opposite one. So the size comes from how long someone will wait after pressing cancel,
--- and the measurement only says the normal path never reaches it.
--- `handbook/architecture/duplex-transport.md`.
M.INTERRUPT_GRACE_MS = 5000

--- Stop the turn a process has open without stopping the process.
---
--- **"Handled" means the process is resident, not that anything was interrupted.** A chat sends
--- `cancel_request()` before *every* message as a zombie reap (`ChatBuffer:send_message`), so on
--- this transport the common case is being asked to stop a process that is sitting idle between
--- turns — and the caller's fallback for "not handled" is a kill. Returning false there would kill
--- the resident process before every single message, which is the exact opposite of the feature.
---
--- **"Handled" is two different facts, and they must not be conflated.** "This is a resident
--- process, so do not reflexively kill it" is one; "the interrupt was actually delivered" is
--- another. Returning true for the second when only the first is known makes a failed write look
--- like a successful cancel, and the user's stop becomes a no-op until the grace timer notices.
--- So a write that does not land falls straight through to the caller's kill.
---
--- @param adapter table the adapter that owns the process, for the fallback kill
--- @param process_id string|nil
--- @return boolean handled false when there is no resident process, or when it could not be asked
function M.stop_turn(adapter, process_id)
  local _, record = Pool.find_by_process_id(process_id)
  if not record then
    return false
  end

  local turn = Routing.turn_of(record)
  if not turn then
    -- Idle between turns: there is nothing to stop, and killing would throw the process away on
    -- the zombie reap that precedes every single message.
    return true
  end

  record._interrupts = (record._interrupts or 0) + 1
  if not DuplexProcess.interrupt(record, record._interrupts) then
    -- The request could not even be written -- a dying process, a closed stdin. Waiting out the
    -- grace period would be waiting for an answer to a question nobody was asked.
    return false
  end

  -- Armed through the turn, which stops every timer it owns the moment it ends. A watchdog that
  -- outlived its turn would fire during the *next* one, on the same process, and kill that instead.
  turn.watch(M.INTERRUPT_GRACE_MS, function()
    vim.notify(
      string.format(
        "[vibing] The CLI did not stop within %dms of being interrupted; stopping the process instead.",
        M.INTERRUPT_GRACE_MS
      ),
      vim.log.levels.WARN
    )
    adapter:cancel(record.process_id)
  end)
  return true
end

return M
