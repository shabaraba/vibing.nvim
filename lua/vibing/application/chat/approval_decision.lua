--- What a tool-approval answer means — the one implementation of it (#778).
---
--- Answering an approval is three things happening together, and until now they lived as one
--- inline block in `ChatBuffer:send_message()`:
---
---   1. the session allow/deny lists are updated (`update_session_permissions`),
---   2. the pending prompt is dropped, which is the *only* mark that says the `:once` grant it
---      produced has been spent,
---   3. the user's chosen option line is replaced by something the model can act on.
---
--- Doing all three, in that order, is what "the approval was consumed" means. Doing two of them is
--- a worker that answers the prompt and then hits the same wall on its next tool call, with no
--- error anywhere.
---
--- `.claude/rules/permissions.md` states the constraint this module exists to satisfy: *"A second
--- implementation of 'what an approval means' is the failure this shape exists to prevent."* Until
--- #778 that was held by routing every answer — human `<CR>` and delegated alike — through
--- `ChatBuffer:send_message()`. That stops being possible the moment an approval can be answered
--- **without ending the turn**: `send_message()` opens with `cancel_request()`, so using it to
--- answer a live turn would kill the very process the feature exists to keep. So the shared thing
--- moves down here, from "the same entry point" to "the same function", and the entry points are
--- free to differ.
---
--- Nothing here starts a turn, sends anything, or touches a transport. It reads a `ChatBuffer` and
--- returns what the caller should say; deciding *how* to say it is the caller's half.
--- @module vibing.application.chat.approval_decision

local M = {}

--- The four answers, in the vocabulary the whole feature shares: the option values
--- `rpc/handlers/permission.lua` offers, the lines `approval_parser.lua` reads back out of the
--- buffer, and the `action` argument `nvim_chat_answer_approval` takes.
--- @type string[]
M.ACTIONS = { "allow_once", "deny_once", "allow_for_session", "deny_for_session" }

--- @param action any
--- @return boolean
function M.is_valid_action(action)
  return type(action) == "string" and vim.tbl_contains(M.ACTIONS, action)
end

--- @param action string
--- @return boolean
function M.is_allow(action)
  return action == "allow_once" or action == "allow_for_session"
end

--- The argument worth repeating back to the model, per tool.
---
--- Not a generic dump of `input`: the retry message is read by the model as an instruction, and a
--- `Write` whose whole `content` is quoted back at it is both useless and expensive. So the
--- *fields* are named, and everything else is left out.
---
--- **Keyed on the field, not on the tool name.** A tool→field table has to be extended for every
--- tool, and nothing fails when it is not — a `Grep` or an MCP tool simply produced
--- `"I approved the Grep tool."` with no argument, next to a prompt that had just printed
--- `Pattern: …`. It also went wrong in the other direction: `WebFetch` was listed as `query`,
--- which is not a field `WebFetch` has, so the one thing telling two fetches apart was dropped.
--- This is the order `event_renderer.input_summary` already reads a call's identity in.
--- @type {key: string, label: string}[]
local IDENTIFYING_FIELDS = {
  { key = "command", label = "command" },
  { key = "file_path", label = "file" },
  { key = "notebook_path", label = "file" },
  { key = "pattern", label = "pattern" },
  { key = "query", label = "query" },
  { key = "url", label = "url" },
}

--- @param tool string
--- @param input table
--- @return string "" or " (label: value)"
function M.input_summary(tool, input)
  for _, field in ipairs(IDENTIFYING_FIELDS) do
    local value = (input or {})[field.key]
    if value ~= nil and value ~= "" then
      return string.format(" (%s: %s)", field.label, value)
    end
  end
  return ""
end

--- What the answered approval is turned into for the model, when the answer can only be delivered
--- as a new turn.
---
--- First person on purpose: on the human path the "I" is the user, and on a delegated one the
--- section header names the chat that answered, so the pronoun still resolves
--- (`approval_delegate.lua`).
--- **`expired` changes what is true, not just the tone.** The two messages below are written for a
--- turn that stopped *at* the prompt: nothing has happened since, so "proceed with the same
--- operation" and "use a different approach" are both instructions about what to do next. After the
--- wait limit those premises are gone — the call was denied, the model saw the refusal and carried
--- on, possibly finishing the turn another way. Telling it to proceed can redo work already done,
--- and telling it to use a different approach describes what it already did.
---
--- So the expired pair **says only what we know and instructs nothing**: the call was refused by
--- the limit, the permission is granted now, and the turn went on afterwards. Whether anything
--- still needs doing is something only the model can see — it is the one that knows what it did
--- with the refusal. Any wording that decides that for it is asserting a state we did not observe.
---
--- What either pair costs or buys in model behaviour is **not measured** — neither wording is. What
--- is knowable without a measurement is only that the original two say something false here.
--- @param action string
--- @param tool string
--- @param input table
--- @param expired boolean? the prompt had already reached its wait limit when it was answered
--- @return string
function M.retry_message(action, tool, input, expired)
  if M.is_allow(action) then
    if expired then
      return string.format(
        "I approved the %s tool%s. That call had already been refused for going unanswered, and "
          .. "the turn carried on afterwards — so check what still needs doing before acting on "
          .. "this.",
        tool,
        M.input_summary(tool, input)
      )
    end
    return string.format(
      "I approved the %s tool%s. Please proceed with the same operation.",
      tool,
      M.input_summary(tool, input)
    )
  end
  if expired then
    return string.format(
      "I denied the %s tool. That call had already been refused for going unanswered, and the turn "
        .. "carried on afterwards — this records the decision rather than asking for anything.",
      tool
    )
  end
  return string.format("I denied the %s tool. Please use a different approach.", tool)
end

--- @class Vibing.ConsumedApproval
--- @field action string
--- @field request_id string? the hook invocation this answers, when it came from one
--- @field tool string
--- @field input table the tool input the prompt was raised for, before the prompt was dropped
--- @field is_allow boolean
--- @field retry_message string What to say to the model when the answer travels as a new turn.
---   Built here even on the in-place route so the two routes cannot drift on what an allow says.

--- Spend a chat's pending approval.
---
--- The order is the contract: `update_session_permissions` reads the tool name off the still-live
--- `_pending_approval`, so dropping the prompt first would record the grant against nothing. And
--- the prompt is dropped only once the permission update has actually succeeded — a chat that lost
--- its grant but kept no way to be asked again is the worse of the two failures.
--- @param chat_buf Vibing.ChatBuffer
--- @param approval {action: string, request_id: string?} `request_id` may be omitted only while
---   exactly one approval is pending; with several waiting at once there is no "the" pending one,
---   and guessing is how one prompt's answer lands on another's grant.
--- @return Vibing.ConsumedApproval|nil consumed nil when nothing was spent
--- @return string|nil error why, when it was not
function M.consume(chat_buf, approval)
  local pending = chat_buf:get_pending_approval(approval and approval.request_id)
  if not pending then
    return nil, "no approval is pending on this chat"
  end
  -- **期限切れでも消費する。** 上限が切ったのは「飛んでいたその1回」であって、ユーザーが許可を
  -- 与える機会ではない。ここで断ると、半日離席して戻った人は**その承認をもう与えられない** —
  -- kill する設計ではプロンプトがターンより長生きして、いつ答えても再試行できていたので、
  -- `approval_wait_sec` を境に今日より悪くなる。この機能に最初に出た懸念がそれだった。
  --
  -- 「その場で答えてはいけない」は別の話で、そちらは構造で守られている: 期限切れの時点で
  -- レジストリのエントリは消えているので `_answer_pending_approval` の `blocked` は nil になり、
  -- 答えは必ず `retry_as_new_turn`（＝今日とまったく同じ経路）に落ちる。ここで断るのは、
  -- 届かない経路ではなく**届く経路のほう**を塞いでいた
  if not M.is_valid_action(approval and approval.action) then
    return nil, string.format("invalid approval action: %s", tostring(approval and approval.action))
  end

  local tool = pending.tool
  local input = pending.input or {}

  -- The tool travels with the action now. `update_session_permissions` used to read it back off
  -- the chat's single pending slot, which stopped being well defined once several approvals can
  -- be open at once — the caller is the only one that knows which of them is being answered.
  local ok, err = pcall(function()
    chat_buf:update_session_permissions({ action = approval.action, tool = tool })
  end)
  if not ok then
    return nil, tostring(err)
  end

  chat_buf:clear_pending_approval(pending.request_id)

  return {
    action = approval.action,
    request_id = pending.request_id,
    tool = tool,
    input = input,
    is_allow = M.is_allow(approval.action),
    retry_message = M.retry_message(approval.action, tool, input, pending.expired),
  }, nil
end

return M
