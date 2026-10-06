--- What answering a CLI's **own** approval means — which is deliberately less than answering a
--- hook's (#861).
---
--- `approval_decision.consume` does three things: update the session allow/deny lists, drop the
--- prompt, and build the sentence the model is told. This one does **two**. The missing one is the
--- point: codex's approval asks whether a call may escape codex's sandbox, and a human saying yes
--- to that has said nothing at all about vibing's `permissions.allow` / `permissions.deny`. Writing
--- to those lists here would widen a permission the user never granted, which is the failure #861
--- names in its own description.
---
--- It is a separate module rather than a flag inside the other one so that a change to how hook
--- approvals are spent cannot reach this path by accident. `approval_decision` dispatches to it
--- from **three** places — `consume`, `find_blocked` and `release` — each asking the prompt's own
--- `kind` which channel owes it something; they are three because the three answers differ, not
--- because the knowledge is duplicated.
---
--- Everything the two **do** share is shared: the returned shape is `Vibing.ConsumedApproval`, and
--- the retry wording comes from `approval_decision.retry_message`, told explicitly what the chosen
--- decision means because codex's vocabulary is not the four words that function can read.
--- @module vibing.application.chat.native_approval_decision

local ApprovalDecision = require("vibing.application.chat.approval_decision")

local M = {}

--- The option the human picked, out of the ones this prompt actually offered.
---
--- Validated against the prompt's own options rather than a global list, because there is no global
--- list: `availableDecisions` differs per request, and a decision one request offered may be
--- meaningless on the next.
--- @param pending table
--- @param action any
--- @return table|nil option
local function chosen(pending, action)
  for _, option in ipairs(pending.options or {}) do
    if option.value == action then
      return option
    end
  end
  return nil
end

--- Spend a chat's pending native approval.
---
--- The order is the same contract as next door, minus the step that is not ours: read what is
--- needed off the live prompt, then drop it. Dropping it is the only mark that says this one was
--- answered, so nothing may fail after it.
--- @param chat_buf Vibing.ChatBuffer
--- @param pending table the chat's copy of the prompt
--- @param approval {action: string, request_id: string?}
--- @return Vibing.ConsumedApproval|nil consumed nil when nothing was spent
--- @return string|nil error why, when it was not
function M.consume(chat_buf, pending, approval)
  local option = chosen(pending, approval and approval.action)
  if not option then
    return nil, string.format("invalid Codex decision: %s", tostring(approval and approval.action))
  end

  local tool = pending.tool
  local input = pending.input or {}

  chat_buf:clear_pending_approval(pending.request_id)

  return {
    action = option.value,
    request_id = pending.request_id,
    tool = tool,
    input = input,
    is_allow = option.is_allow,
    -- What goes on the wire, kept exactly as the CLI offered it rather than rebuilt from the slug:
    -- an object decision carries a body, and re-encoding that body here would be a second copy of
    -- the CLI's schema.
    raw_decision = option.raw,
    retry_message = ApprovalDecision.retry_message(option.value, tool, input, pending.expired, option.is_allow),
  }, nil
end

return M
