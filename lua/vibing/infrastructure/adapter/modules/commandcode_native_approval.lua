--- Command Code's own `session/request_permission`, which is a **second** gate and not vibing's hook.
---
--- **Why this exists.** In the `acp` (duplex) transport Command Code runs its own permission engine
--- before it calls the mod bridge, and for a call the engine would gate it sends the client a
--- `session/request_permission` request over ACP (**measured 2026-11-04, 1.88.2** — `commandcode
--- --mod <bridge> --yolo acp` still sends one for a shell command, so `--yolo` does not lift this
--- gate the way it lifts the print-mode one). A client that does not answer — or answers with a
--- JSON-RPC error, which is what vibing.nvim did before this module existed — has the call marked
--- `failed` with `Permission denied by the user.` and the turn ends. So the request has to be
--- answered.
---
--- **Why answering `allow_once` is not "approve everything".** The two gates are ordered the other
--- way round from grok's: here the engine asks *first* and `beforeToolCall` (vibing's mod bridge)
--- runs *after* it, on the call the engine has now allowed. Answering `allow_once` therefore does
--- not decide anything vibing has not already decided — it only lets the call reach the bridge,
--- which is still the sole authority: a call vibing's own gate denies is blocked by
--- `beforeToolCall` afterwards. The engine layer is not where a vibing.nvim chat's permissions
--- live, so it must not be the layer that refuses.
---
--- **`allow_once`, never `allow_always`.** The session-wide option would retire the engine gate for
--- every later call in the chat, silently widening what a *future* turn may do without the request
--- being seen at all. Scoping to the single call keeps the mod bridge the only thing that
--- accumulates permission.
---
--- This is **not** the approval-without-kill path (#778/#861): nothing here waits for a human, so
--- `native_approval.measured_wait_floor_sec` is not required and is deliberately absent from the
--- Command Code descriptor.
--- @module vibing.infrastructure.adapter.modules.commandcode_native_approval

local Process = require("vibing.infrastructure.adapter.modules.duplex_process")

local M = {}

local METHOD = "session/request_permission"

--- @param method string|nil
--- @return boolean
function M.handles(method)
  return method == METHOD
end

--- The first option offered with this `kind`.
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
--- **Every request is answered.** A withheld reply is not a refusal here — Command Code blocks
--- inside its own turn waiting for one, so a silent drop hangs the chat with no way out but a
--- cancel. Hence the fall-through: no `allow_once` on offer means `reject_once`, and no options at
--- all mean the ACP `cancelled` outcome, which Command Code reports back as a cancelled turn
--- rather than a hang.
--- @param record Vibing.DuplexProcess
--- @param msg table the decoded JSON-RPC request
--- @return boolean answered
--- @return string|nil notice what the user needs told, when the answer was a refusal. Returned
---   rather than rendered: `commandcode_duplex_protocol.render` is the one place a turn is resolved
---   from a deferred callback, and a second renderer here would be a second answer to that question.
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
    "Command Code asked for permission to run "
      .. tool
      .. " and offered no single-use approval, so vibing.nvim refused it."
end

return M
