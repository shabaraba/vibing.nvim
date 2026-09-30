--- What a turn hands back, and how long it may take to say anything at all (#782).
---
--- Every `Vibing.Response` the adapter layer builds was a table literal at its call site — eleven
--- of them across the two transports, of which four pairs were the same response written twice:
--- a failure before the process existed, a cancellation, a process that exited, and the
--- first-response watchdog. Each pair was a place where changing one half silently left the two
--- transports disagreeing about the same thing.
---
--- **Both ids are on every response, including the ones built before any process existed.**
--- `_turn_id` is what `send_message`'s staleness check compares and `_process_id` is what the
--- session read-back uses, so a response missing either one is indistinguishable from a response
--- belonging to someone else.
---
--- `handbook/architecture/duplex-transport.md` → "One answer to the first-byte question".
--- @module vibing.infrastructure.adapter.modules.turn_outcome

local M = {}

--- How long the CLI gets to produce its first byte before it is treated as hung.
---
--- **One number, read at the moment each watchdog is armed.** Both transports ask the same
--- question — the oneshot path of a process that was told to resume a session, the resident path of
--- every turn, since there is no exit to notice there — and there has never been a reason for the
--- two answers to differ. It used to be two constants plus an alias captured at module load, which
--- made the "keep these equal" comments on both of them unverifiable: nothing could observe either
--- value changing.
---
--- `execute()` spends the same budget on its whole blocking wait (`cli_runtime.lua`), which is
--- deliberate rather than reuse of a convenient number: `execute()` is only ever reached by a
--- lightweight call — no tools, no MCP servers, no hooks — so the entire call *is* waiting for the
--- CLI to answer.
M.FIRST_RESPONSE_TIMEOUT_MS = 120000

--- @param ids Vibing.RequestIds
--- @param content string what the turn produced before it ended; `""` when that is nothing
--- @param err string|nil
--- @return Vibing.Response
local function response(ids, content, err)
  return {
    content = content,
    error = err,
    _turn_id = ids.turn_id,
    _process_id = ids.process_id,
  }
end

--- A turn that ended on its own terms, successfully or not.
---
--- `err` nil is the success case; anything else is the CLI's own account of the failure (a non-zero
--- exit, its `result` line's errors, a prompt that could not be written).
--- @param ids Vibing.RequestIds
--- @param content string
--- @param err string|nil
--- @return Vibing.Response
function M.ended(ids, content, err)
  return response(ids, content, err)
end

--- A turn a human, or the code acting for one, stopped.
---
--- `_cancelled` is what keeps `send_message` from writing an `**Error:**` line and from reporting
--- the stop as `error` — a cancelled turn is a turn nobody is waiting on, not a broken one
--- (`.claude/rules/features.md`).
--- @param ids Vibing.RequestIds
--- @param content string whatever arrived before the stop; `""` when nothing had
--- @return Vibing.Response
function M.cancelled(ids, content)
  local out = response(ids, content, "Cancelled")
  out._cancelled = true
  return out
end

--- The response for a CLI that never produced a first byte within `FIRST_RESPONSE_TIMEOUT_MS`.
---
--- **Hand this back before killing anything.** Both transports end an open turn as a plain
--- "Cancelled" on their way through a kill, and completing a turn is idempotent, so whichever
--- response arrives first wins. A kill that runs first therefore throws this one away — taking
--- `_session_corrupted` with it, so the session is never reset and no notice is written, while the
--- `_cancelled` on the response that replaced it suppresses the error line too. The turn ends with
--- an empty assistant section and no message of any kind, which is what both transports did before
--- #782 (duplex fixed it in #781 and left the oneshot path as it was).
---
--- @param ids Vibing.RequestIds
--- @return Vibing.Response
function M.first_response_timeout(ids)
  local out = response(ids, "", "Session resume timeout")
  out._session_corrupted = true
  return out
end

return M
