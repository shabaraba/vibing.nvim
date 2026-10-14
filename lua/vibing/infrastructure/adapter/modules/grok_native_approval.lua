--- Grok's own `session/request_permission`, which is a **second** gate and not vibing's hook.
---
--- **Why answering `allow_once` here is not "approve everything".** The two gates are ordered, and
--- the order was measured against grok 1.0.50: with a `pre_tool_use` hook that denies, six tool
--- calls in one turn were refused (`"blocked":true`, `write` / `list_dir` / `grep` /
--- `run_terminal_command`), nothing was written, and **no `session/request_permission` was sent at
--- all**. The hook runs first and a denial ends the call there. So a request that reaches this
--- module is for a call vibing's own gate has already permitted — including one the user answered
--- by eye, because an `ask` is resolved inside the blocked hook before the tool proceeds.
---
--- What is left to decide is therefore not "may this run" but "should the human be asked a second
--- time about something they already approved", and the answer to that is no.
---
--- **`allow_once`, never `allow_always`.** The session-wide option would retire grok's gate for
--- every later call in the chat, which also silently widens what a *future* turn may do without
--- vibing's hook being consulted by grok at all. Scoping to the single call keeps vibing's gate the
--- only thing that accumulates permission.
---
--- This is **not** the approval-without-kill path (#778/#861): nothing here waits for a human, so
--- `native_approval.measured_wait_floor_sec` is not required and is deliberately absent from the
--- grok descriptor.
--- @module vibing.infrastructure.adapter.modules.grok_native_approval

local Process = require("vibing.infrastructure.adapter.modules.duplex_process")

local M = {}

local METHOD = "session/request_permission"

--- @param method string|nil
--- @return boolean
function M.handles(method)
  return method == METHOD
end

--- The first option grok offered with this `kind`.
--- @param params table
--- @param kind string
--- @return string|nil option_id
local function option_for(params, kind)
  for _, option in ipairs(params.options or {}) do
    if option.kind == kind then
      return option.optionId
    end
  end
  return nil
end

--- Answer the request, exactly once.
---
--- **Every request is answered.** A withheld reply is not a refusal here — grok blocks inside its
--- own turn waiting for one, so a silent drop hangs the chat with no way out but a cancel. Hence
--- the fall-through: no `allow_once` on offer means `reject_once`, and no options at all mean the
--- ACP `cancelled` outcome, which grok reports back as a cancelled turn rather than a hang.
--- @param record Vibing.DuplexProcess
--- @param msg table the decoded JSON-RPC request
--- @return boolean answered
--- @return string|nil notice what the user needs told, when the answer was a refusal. Returned
---   rather than rendered: `grok_duplex_protocol.render` is the one place a turn is resolved from a
---   deferred callback, and a second renderer here would be a second answer to that question.
function M.handle(record, msg)
  local params = msg.params or {}
  local allow = option_for(params, "allow_once")
  if allow then
    local answered = Process.write(record, {
      jsonrpc = "2.0",
      id = msg.id,
      result = { outcome = { outcome = "selected", optionId = allow } },
    })
    -- Silent on the ordinary path: it reports a decision vibing's own gate already made and
    -- already rendered. Only a refusal needs saying, or the user sees a tool that did nothing.
    return answered, nil
  end

  local reject = option_for(params, "reject_once")
  local outcome = reject and { outcome = "selected", optionId = reject } or { outcome = "cancelled" }
  local answered = Process.write(record, { jsonrpc = "2.0", id = msg.id, result = { outcome = outcome } })
  if not answered then
    return false, nil
  end
  local tool = (params.toolCall or {}).title or "a tool call"
  return true,
    "Grok asked for permission to run "
      .. tool
      .. " and offered no single-use approval, so vibing.nvim refused it."
end

return M
