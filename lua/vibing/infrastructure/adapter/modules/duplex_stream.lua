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
--- switch are wired is `duplex_routing.lua`. A turn the CLI started by itself is opened here too,
--- with no prompt written (`duplex_foreign_turn.lua`).
--- @module vibing.infrastructure.adapter.modules.duplex_stream

-- Safe at load time: `cli_runtime` reaches back into the duplex modules only from inside its
-- methods, so this direction is the only one resolved while either module is still loading.
local BackgroundTasks = require("vibing.infrastructure.adapter.modules.background_tasks")
local CliRuntime = require("vibing.infrastructure.adapter.modules.cli_runtime")
local DuplexTurn = require("vibing.infrastructure.adapter.modules.duplex_turn")
local ForeignTurn = require("vibing.infrastructure.adapter.modules.duplex_foreign_turn")
local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
local RequestBuilder = require("vibing.infrastructure.adapter.modules.request_builder")
local Routing = require("vibing.infrastructure.adapter.modules.duplex_routing")
local TurnOutcome = require("vibing.infrastructure.adapter.modules.turn_outcome")

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
--- @return string|nil key, any err whatever pcall returned, for `report_build_failure` to strip
local function reuse_key(params)
  local ok, cmd = pcall(params.descriptor.build, params.prompt, params.opts, nil, params.config, params.hook_arg)
  if not ok then
    return nil, cmd
  end
  return table.concat(cmd, "\30"), nil
end

--- What the process will need in order to report the background subagents it takes down with it, once
--- nobody is left to report them itself (#840 — `BackgroundTasks.report_orphaned` says when that is).
---
--- Stored on the **record**, so a late reclaim of a process that has already been replaced reports
--- that process's own ledger rather than its successor's. Written on every turn rather than only the
--- one that spawned, because `run` is the only place these values are in scope and re-stating them
--- costs one table; nothing in the plan actually varies between the turns of one process.
---
--- The chat is not woken from here: `adapter/` requires nothing from `application/`, and whether a
--- chat needs a turn is not an adapter question — only *what this backend wrote and where* is. So the
--- finding leaves through the callback the chat layer handed in, the same shape as
--- `on_approval_required`. Nothing is stored at all when there is no callback, which is every
--- lightweight call.
--- @param params Vibing.DuplexRunParams
--- @param record Vibing.DuplexProcess
local function plan_orphan_report(params, record)
  local on_orphaned = params.opts.on_subagents_orphaned
  if not on_orphaned then
    -- Cleared rather than left, so a chat that stops supplying the callback cannot be reported
    -- through the plan its previous turn installed.
    record._orphan_report = nil
    return
  end
  record._orphan_report = {
    on_orphaned = on_orphaned,
    recover = params.descriptor.recover_unreported_tasks,
    adapter = params.adapter,
  }
end

--- The id this turn's prompt travels under, so the CLI can name it back.
---
--- Prefixed rather than bare so a `user_message_uuid` in a capture says where it came from; the
--- CLI does not validate the shape (measured: arbitrary strings are echoed unchanged).
--- @param turn_id string
--- @return string
function M.prompt_uuid(turn_id)
  return "vibing-" .. turn_id
end

--- The process for a turn of vibing's own: reused when its argv still matches, spawned otherwise.
--- @param params Vibing.DuplexRunParams
--- @param chat_key number|string
--- @return Vibing.DuplexProcess|nil record
--- @return string|nil err absent with no record when the failure was already handed to `finish`
local function acquire(params, chat_key)
  local ids = params.ids
  local descriptor = params.descriptor
  local argv_key, key_err = reuse_key(params)
  if not argv_key then
    -- The same helper the oneshot path calls, so a missing binary reads as a message in both
    -- transports rather than as a `cli_command_builder.lua:214:` stack location.
    CliRuntime.report_build_failure(ids, key_err, params.finish)
    return nil, nil
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
    return nil, err or "Could not start the resident CLI process."
  end
  -- A turn the CLI started by itself that the chat has not adopted yet goes where its lines went
  -- before, ahead of this turn — replayed into it, its `result` would end this one.
  ForeignTurn.flush(record)
  return record
end

--- @param record Vibing.DuplexProcess
--- @return boolean
local function holds_cli_turn(record)
  return record._foreign ~= nil
end

--- Start a turn on a resident process.
---
--- With `opts._adopt_cli_turn` the turn is one the CLI already started by itself: nothing is written
--- to it, and the lines held since its `init` are replayed into the turn opened here.
--- @param params Vibing.DuplexRunParams
--- @return string turn_id
--- @return string process_id
function M.run(params)
  local ids = params.ids
  local chat_key = params.opts.chat_bufnr
  local descriptor = params.descriptor
  local adopting = params.opts._adopt_cli_turn == true

  local record, err
  if adopting then
    -- `acquire`'s argv comparison is skipped on purpose: the turn is already running under the flags
    -- the process was spawned with, and a mismatch could only restart the process and lose it.
    record = Pool.claim(chat_key, holds_cli_turn)
    err = "The turn the CLI started by itself is no longer running."
  else
    record, err = acquire(params, chat_key)
  end
  if not record then
    if err then
      vim.schedule(function()
        params.finish(TurnOutcome.ended(ids, "", err))
      end)
    end
    return ids.turn_id, ids.process_id
  end

  -- A reused process keeps the id it was spawned with, because that is the one its child
  -- environment (and therefore every hook it fires) already names.
  ids.process_id = record.process_id
  params.event_context.processId = record.process_id
  params.event_context._decoder_state = record.decoder_state
  -- Per process, for the same reason the decoder state is: a background subagent outlives the turn
  -- that launched it, so the notification that takes it off the ledger lands in some later turn's
  -- context or in the idle one. `background_tasks.share` states what a per-turn copy gets wrong.
  BackgroundTasks.share(params.event_context, record)
  Routing.idle_context(record, params.event_context.sessionManager)
  params.adapter._processes[record.process_id] = Routing.cancellable_handle(record, chat_key)
  plan_orphan_report(params, record)
  -- Rewritten every turn like the orphan plan, so a chat that stops supplying it is never offered one.
  record._on_cli_turn = params.opts.on_cli_turn

  if adopting then
    -- No `promptUuid`, so `duplex_turn.ends_this_turn` takes the first `result` — the CLI's own.
    DuplexTurn.open(params, record, chat_key)
    for _, line in ipairs(ForeignTurn.take(record)) do
      record.on_line(line, record)
    end
    return ids.turn_id, record.process_id
  end

  -- Set before the turn opens, because `duplex_turn` reads it off the context to decide which
  -- `result` is this turn's. Derived from the turn id rather than minted: the two name the same
  -- thing, and one of them travelling under a second identity is a third id to keep in step.
  params.event_context.promptUuid = M.prompt_uuid(ids.turn_id)

  local complete = DuplexTurn.open(params, record, chat_key)

  local prompt =
    RequestBuilder.prompt_text(descriptor.request, params.prompt, params.opts, params.opts._session_id, params.config)
  local sent = descriptor.duplex.send_prompt(record, prompt or params.prompt, params)
  if not sent then
    -- Reported before the kill, for the reason `turn_outcome.first_response_timeout` states:
    -- `Pool.stop` completes this turn as "Cancelled" on its way out, and `complete` is idempotent,
    -- so killing first would replace this message with one that says nothing about what went wrong.
    -- `ids` already names the process that was acquired, per the assignment above.
    complete(TurnOutcome.ended(ids, "", "Could not write the prompt to the resident CLI process."))
    Pool.stop(chat_key, "unresponsive")
  end

  return ids.turn_id, record.process_id
end

return M
