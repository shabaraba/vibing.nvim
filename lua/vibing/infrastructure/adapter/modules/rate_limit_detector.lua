--- Usage-limit detection, shared by every CLI adapter
---
--- Which channels each backend actually has, and what follows from the ones it lacks:
--- `handbook/features/usage-limits.md` → "Which Channel Each Backend Has".
---
--- @module vibing.infrastructure.adapter.modules.rate_limit_detector

local RateLimit = require("vibing.core.utils.rate_limit")
local RateLimitHandler = require("vibing.infrastructure.rpc.handlers.rate_limit")

local M = {}

--- Merge every channel that can report a usage limit and, if any says the turn was turned away,
--- hang the result on the response for `send_message.lua` to act on.
---
--- A channel the backend does not have contributes nothing, so every adapter calls this the same
--- way. The one judgement encoded here is the gate on `response.error`: that is set only when the
--- process exited non-zero, whereas the adapters' `error_output` also collects benign stderr, which
--- every one of these CLIs writes.
---
--- @param response Vibing.Response Mutated in place when a limit is detected
--- @param turn_id string The turn being completed, used to claim a parked StopFailure report
--- @param event_context table|nil The adapter's event context, if it tracks stream-level info
function M.attach(response, turn_id, event_context)
  local merged = RateLimit.merge(
    event_context and event_context.rateLimitInfo,
    RateLimitHandler.take_failure(turn_id),
    response.error and RateLimit.from_error_text(tostring(response.error))
  )

  if merged and merged.rejected then
    response._rate_limit_info = merged
  end
end

return M
