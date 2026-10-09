--- What a Codex app-server approval request offers the human, as chat option values (#861).
---
--- Measured against codex-cli 0.160.1 rather than read off the docs. `availableDecisions` is a
--- **heterogeneous array**: a plain string for a decision that carries no payload, a single-key
--- object for one that does. An observed `item/commandExecution/requestApproval` offered
---
---   ["accept", {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": [...]}}, "cancel"]
---
--- and an observed `item/fileChange/requestApproval` offered **no `availableDecisions` key at all**.
---
--- Two measured facts shape this module:
---
---   * **The payload is kept, never rebuilt.** `raw` is the exact element codex sent, echoed back
---     verbatim as `{ decision = raw }`. Reconstructing an object body from its own slug would be a
---     second encoding of codex's schema, and the amendment bodies are the part most likely to grow
---     a field between releases.
---   * **`decline` is always offered, listed or not.** It appeared in none of the observed
---     `availableDecisions` and is nevertheless honoured: replying `{ decision = "decline" }` marks
---     that one call `declined`, the model is told, and the turn completes normally. Without it a
---     human whose only listed options are `accept` and `cancel` could refuse one command only by
---     aborting the whole turn — which is the opposite of what refusing a single call means
---     everywhere else in this plugin.
--- @module vibing.infrastructure.adapter.modules.codex_native_decisions

local M = {}

M.DECLINE = "decline"

--- The option values a request with no `availableDecisions` gets. `accept` is not guessed: both
--- legacy methods and `item/fileChange/requestApproval` take the same `{ decision = ... }` reply,
--- and these two are the pair every observed request accepted.
local IMPLIED = { "accept", M.DECLINE }

--- Human wording per known decision. An unknown one still becomes an option — codex adding a
--- decision must not make it unofferable — it just gets no sentence of its own.
local DESCRIPTIONS = {
  accept = "Run it this once",
  accept_for_session = "Run it, and allow the same for the rest of this Codex thread",
  accept_with_execpolicy_amendment = "Run it, and let Codex remember this command pattern",
  apply_network_policy_amendment = "Apply the network policy change Codex proposed",
  decline = "Refuse this one call; the turn carries on",
  cancel = "Abort the turn",
}

--- `acceptWithExecpolicyAmendment` → `accept_with_execpolicy_amendment`.
---
--- This is for **readability** — the word a human leaves on the option line. It is deliberately no
--- longer load-bearing for safety: `approval_parser.action_pattern` escapes what it interpolates
--- (`vim.pesc`), so a decision carrying `-` or `%` is handled where the pattern is built rather
--- than by every producer of a value remembering to fold it first.
--- @param key string
--- @return string
function M.slug(key)
  local out = tostring(key):gsub("(%u)", "_%1"):lower():gsub("[^a-z0-9]+", "_")
  return (out:gsub("^_+", ""):gsub("_+$", ""))
end

--- Whether choosing this decision lets the call run.
---
--- Read off the value rather than a list, because the list is codex's and grows: every observed
--- "the call proceeds" decision is an `accept*`, and every other one (`decline`, `cancel`) refuses.
--- A new `accept…` variant is therefore allowed by default and a new refusal is refused by default,
--- which is the safe direction for each.
--- @param value string
--- @return boolean
function M.is_allow(value)
  return vim.startswith(value, "accept")
end

--- @param element any one `availableDecisions` entry
--- @return string|nil value, any raw
local function unpack_decision(element)
  if type(element) == "string" then
    return M.slug(element), element
  end
  if type(element) == "table" then
    -- A single-key object. `pairs` rather than indexing a known name: the key *is* the decision,
    -- and this module is deliberately ignorant of which ones exist.
    for key, _ in pairs(element) do
      return M.slug(key), element
    end
  end
  return nil, nil
end

--- @class Vibing.CodexDecisionOption
--- @field value string the word the human leaves on the option line
--- @field label string `"<value> - <sentence>"`, the grammar `approval_parser` reads back
--- @field raw any what to send as `{ decision = raw }`
--- @field is_allow boolean

--- Turn codex's `availableDecisions` into the chat's option list.
--- @param available any[]|nil as codex sent it
--- @return Vibing.CodexDecisionOption[]
function M.options(available)
  local options, seen = {}, {}

  local function add(value, raw)
    if not value or value == "" or seen[value] then
      return
    end
    seen[value] = true
    local description = DESCRIPTIONS[value]
    table.insert(options, {
      value = value,
      label = description and (value .. " - " .. description) or (value .. " - Codex decision"),
      raw = raw,
      is_allow = M.is_allow(value),
    })
  end

  for _, element in ipairs(type(available) == "table" and available or {}) do
    add(unpack_decision(element))
  end

  if #options == 0 then
    for _, value in ipairs(IMPLIED) do
      add(value, value)
    end
  end

  -- Last, so it sits below what codex itself offered, and unconditionally, for the reason in the
  -- module comment. `add` is a no-op when codex did list it.
  add(M.DECLINE, M.DECLINE)

  return options
end

--- The decision `backends.codex.auto_approve` answers with, or `nil` if this request offers none.
---
--- Plain `accept` is preferred over every other `accept…`, and that is the whole of the rule. The
--- variants carry a **side effect beyond this call**: `accept_with_execpolicy_amendment` writes a
--- command pattern into codex's own policy and `accept_for_session` grants the rest of the thread.
--- A human choosing one of those has read what it would remember; a flag that said "approve this"
--- has not, so it takes the narrowest option that lets the call run and leaves the broader ones to
--- the human path. `nil` means **fall back to asking** -- never to refusing: a request offering no
--- `accept…` at all is one this flag has nothing to say about, and silently declining it would make
--- turning the flag on *lose* an approval the user could have granted by hand.
--- @param options Vibing.CodexDecisionOption[]
--- @return any|nil raw the body for `{ decision = raw }`
function M.auto_choice(options)
  local fallback = nil
  for _, option in ipairs(options or {}) do
    if option.is_allow then
      if option.value == "accept" then
        return option.raw
      end
      fallback = fallback == nil and option.raw or fallback
    end
  end
  return fallback
end

--- The reply body for a decision that nobody chose.
---
--- One place, because three exits need it — the wait limit, the chat closing and Neovim exiting —
--- and they must not drift into "one of them aborts the turn".
--- @return any
function M.refusal()
  return M.DECLINE
end

return M
