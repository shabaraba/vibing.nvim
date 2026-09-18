--- The gate's own permission question, answered over the control channel (#778, decision 1).
---
--- ## Why anything is answered here at all
---
--- An approval the human granted is released with `defer`, not `allow`. That is the whole point:
--- `allow` would skip the CLI's own gate, and measurement put two of the user's own protections
--- inside it. So the hook defers, the gate runs, and the gate asks its question back — here.
---
--- Measured against claude 2.1.236 (`handbook/architecture/approval-without-kill.md`):
---
---   1. toolset construction  — a tool-NAME deny removes the tool; the hook never runs for it
---   2. PreToolUse hook       — where vibing decides, and where an approval blocks
---   3. granular deny rules   — `Bash(rm -rf:*)`; evaluated after the hook
---   4. can_use_tool          — this module; reached only by calls that survived 1 and 3
---
--- ## Why the answer is `allow`, with no second opinion
---
--- Everything arriving here has already passed vibing's own evaluation at step 2 — the hook runs
--- for every tool (matcher `.*`) and fails closed — and the user's own deny rules at step 3. Both
--- gates have had their say. Re-deciding here would mean running `can_use_tool` a second time on a
--- verdict that was already reached and, for an `ask`, already **consumed**: a `:once` grant is
--- removed from its list when the human's answer is spent (`approval_decision.consume`), so asking
--- again would find it gone and refuse the call the human just approved.
---
--- The deadline therefore stays where it was measured. The human waits at step 2, inside the hook,
--- against claude's measured 1090s floor; this reply is written the moment the question arrives.
--- Moving the wait here instead would have put it on a control-channel timeout that **nothing has
--- measured**, and traded a known number for an unknown one.
---
--- @module vibing.infrastructure.adapter.modules.duplex_control

local M = {}

--- The envelope the CLI acts on, established by `tests/perf/permission_prompt_tool.sh` (arm A).
--- Three candidate shapes were tried and the first was accepted, so this is a recorded fact rather
--- than a guess; the harness kept the log (`.vibing/probe/permission-prompt-tool/stdio-allow/`).
--- Do not "simplify" the nesting — a shape the CLI does not recognise is ignored with an
--- `Ignoring can_use_tool control_response` and the turn stalls until the request times out.
--- @param request_id string
--- @param input table|nil the tool input to run, echoed back unchanged
--- @return table
function M.allow_response(request_id, input)
  return {
    type = "control_response",
    response = {
      subtype = "success",
      request_id = request_id,
      response = { behavior = "allow", updatedInput = input or vim.empty_dict() },
    },
  }
end

--- Is this line the gate asking whether a tool may run?
--- @param msg table a decoded stdout line
--- @return boolean
function M.is_permission_request(msg)
  return type(msg) == "table"
    and msg.type == "control_request"
    and type(msg.request) == "table"
    and msg.request.subtype == "can_use_tool"
    and type(msg.request_id) == "string"
end

--- Answer one, if that is what this line is.
---
--- Returns whether the line was consumed, so the router can keep it away from the decoder: a
--- `control_request` is not a turn event, and handing it on would have the decoder ignore a line
--- that still owes a reply.
--- @param msg table a decoded stdout line
--- @param respond fun(payload: table): boolean writes one JSON line to the process's stdin
--- @return boolean consumed
function M.try_answer(msg, respond)
  if not M.is_permission_request(msg) then
    return false
  end

  local sent = respond(M.allow_response(msg.request_id, msg.request.input))
  if not sent then
    -- Nothing here can recover it: the CLI is waiting on a reply that will never arrive, and the
    -- only other party that could end that wait is the CLI's own timeout. Say so once, loudly,
    -- rather than letting the turn look like a model that stopped talking.
    vim.notify(
      string.format(
        "[vibing] could not answer the CLI's permission question for %s; the turn will stall until the CLI gives up",
        tostring(msg.request.tool_name)
      ),
      vim.log.levels.ERROR
    )
  end
  return true
end

return M
