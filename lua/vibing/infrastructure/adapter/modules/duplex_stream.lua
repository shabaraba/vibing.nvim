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

-- Safe at load time: `cli_runtime` reaches back into the duplex modules only from inside its
-- methods, so this direction is the only one resolved while either module is still loading.
local CliRuntime = require("vibing.infrastructure.adapter.modules.cli_runtime")
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
--- @return string|nil key, any err whatever pcall returned, for `report_build_failure` to strip
local function reuse_key(params)
  local ok, cmd = pcall(params.descriptor.build, params.prompt, params.opts, nil, params.config, params.hook_arg)
  if not ok then
    return nil, cmd
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
    -- The same helper the oneshot path calls twenty lines up, so a missing binary reads as a
    -- message in both transports rather than as a `cli_command_builder.lua:214:` stack location.
    CliRuntime.report_build_failure(ids, key_err, params.finish)
    return ids.turn_id, ids.process_id
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

return M
