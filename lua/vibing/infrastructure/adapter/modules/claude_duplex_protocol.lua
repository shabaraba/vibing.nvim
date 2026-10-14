--- Claude stdin stream-json. Processes, turns and timers belong to the shared transport.
local Process = require("vibing.infrastructure.adapter.modules.duplex_process")
local Processor = require("vibing.infrastructure.adapter.modules.cli_event_processor")

local M = {}

local INTERRUPT_REQUEST_PREFIX = "vibing-interrupt-"

--- Begin a turn by handing the CLI a user message on stdin.
---
--- `--input-format stream-json` takes the same envelope the CLI emits, so the prompt travels as a
--- plain `user` message rather than as an argv argument. The content is a string rather than a
--- one-element block list: both are accepted, and the string form is what the CLI's own replay
--- emits back.
---
--- **The envelope's `uuid` is the only thing that says which turn is ours.** The CLI echoes it
--- back on that prompt's `result` as `user_message_uuid`, and on the `command_lifecycle` lines it
--- only emits when one was supplied. A turn the CLI started by itself carries neither field, which
--- is what `duplex_turn.ends_this_turn` reads. Any string is accepted -- it is not validated as a
--- UUID. `handbook/architecture/duplex-transport.md` -> "Whose `result` is this?".
--- @param record Vibing.DuplexProcess
--- @param prompt string
--- @param params Vibing.DuplexRunParams
--- @return boolean sent
function M.send_prompt(record, prompt, params)
  return Process.write(record, {
    type = "user",
    uuid = params.event_context.promptUuid,
    message = { role = "user", content = prompt },
  })
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
  return Process.write(record, {
    type = "control_request",
    request_id = INTERRUPT_REQUEST_PREFIX .. tostring(seq),
    request = { subtype = "interrupt" },
  })
end

--- Resolve the context at delivery time, including lines received between turns.
--- @param record Vibing.DuplexProcess
--- @param line string
--- @return boolean
function M.process_line(record, line)
  local context = record._turn and record._turn.context or record._idle_context
  if context then
    return Processor.processLine(line, context)
  end
  return false
end

return M
