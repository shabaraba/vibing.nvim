--- The third producer of "wake this chat".
---
--- A background subagent outlives the turn that launched it, and the CLI is supposed to deliver a
--- `task_notification` and start a new turn by itself. When it does not, nothing else will: the
--- process serving a turn dies with it (oneshot) or sits idle (duplex), and the only way to deliver
--- anything to a chat is to start a new turn on it. So a turn that ends with subagents still
--- outstanding leaves the chat unreachable until a human types into it — the user-visible symptom
--- being "the response just stopped" (#820).
---
--- **The notice is driven by the outstanding ledger, never by what recovery found.** Recovery only
--- yields text for a subagent that already *finished*; the one still running has nothing on disk
--- yet, so keying the notice on recovered text is silence in exactly the state that needs a turn.
---
--- **Not behind `agent.chat_notifications.enabled`.** Same "cannot leave this stop on its own" class
--- as `asked_question` / `waiting_approval` / `error` in `completion_notifier.lua`: an opt-in would
--- leave the silent stall as the default behaviour.
---
--- Why this is a separate producer rather than a `completion_notifier` edge (that module is a
--- subscription graph keyed on a *pair* of chats, and this is a self-wake), and why no wake budget
--- is needed (the ledger is per turn, so one outstanding set cannot wake twice):
--- `handbook/features/chat-ui.md` → "A turn that ends with subagents outstanding".
---@class Vibing.Application.OutstandingSubagents
local M = {}

---@param entry Vibing.BackgroundTask
---@return string
local function name_of(entry)
  if entry.description and entry.description ~= "" then
    return string.format("`%s` — %s", entry.task_id, entry.description)
  end
  return string.format("`%s`", entry.task_id)
end

---The notice a chat is woken with.
---
---Says which subagents produced an answer and which are still owed one, because the two need
---different things from the model: the first is already in hand, the second has to be collected.
---
---Walks `unreported` rather than either list separately, so both groups name a task the same way
---and in the ledger's own order, and so a recovered entry with no matching launch cannot appear as
---a block belonging to nothing.
---@param unreported Vibing.BackgroundTask[] everything still owed a completion notification
---@param recovered Vibing.RecoveredSubagent[] the subset whose transcript had an answer in it
---@return string
function M.notice_body(unreported, recovered)
  local text_of = {}
  for _, item in ipairs(recovered) do
    if item.task_id then
      text_of[item.task_id] = item.text
    end
  end

  local answered, still_owed = {}, {}
  for _, entry in ipairs(unreported) do
    table.insert(text_of[entry.task_id] and answered or still_owed, entry)
  end

  local lines = {
    string.format(
      "This turn ended with %d background subagent(s) that never reported a completion. "
        .. "The CLI did not start a new turn for them, so this chat would not have run again.",
      #unreported
    ),
  }

  if #answered > 0 then
    table.insert(lines, "")
    table.insert(lines, "Recovered from their own transcripts:")
    for _, entry in ipairs(answered) do
      table.insert(lines, "")
      table.insert(lines, string.format("### %s", name_of(entry)))
      table.insert(lines, "")
      table.insert(lines, text_of[entry.task_id])
    end
  end

  if #still_owed > 0 then
    table.insert(lines, "")
    table.insert(lines, "Nothing recoverable yet for these — they may still be running:")
    table.insert(lines, "")
    for _, entry in ipairs(still_owed) do
      table.insert(lines, string.format("- %s", name_of(entry)))
    end
    table.insert(lines, "")
    table.insert(
      lines,
      "Collect their output before continuing (`TaskOutput`, or `SendMessage` with the agent id). "
        .. "If they are gone, say so and re-dispatch rather than waiting — nothing will wake this "
        .. "chat again on its own."
    )
  else
    table.insert(lines, "")
    table.insert(lines, "Continue the task these were launched for.")
  end

  return table.concat(lines, "\n")
end

---Wake the chat about the background subagents its turn left behind.
---
---Reads the adapter's two findings and decides; the adapter decides neither, because *which*
---backend wrote a transcript and where is an adapter fact while "does this chat need a turn" is
---not.
---@param response table
---@param bufnr number|nil
---@return boolean woken
function M.wake(response, bufnr)
  -- The outstanding set alone decides, which is this module's whole point: `recovered` is a subset
  -- of it, so a second clause here could only ever contradict the rule above.
  local unreported = response and response._unreported_subagents or {}
  if #unreported == 0 then
    return false
  end
  local recovered = response._recovered_subagents or {}

  -- A chat that was wiped while its turn ran has nowhere to be woken. Checked here rather than
  -- left to the queue: `flush` reports an invalid bufnr as "vanished without a BufDelete event",
  -- which is a real anomaly worth a warning and not what an ordinary closed chat is.
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return false
  end

  -- `_cancelled` covers both ways a turn ends without the chat being abandoned: the human hit
  -- `:VibingCancel`, or the turn was killed to draw a question / approval on a backend that cannot
  -- wait in place. Neither may be woken — the first was explicitly stopped, and the second already
  -- has a prompt on screen that the human's answer will start the next turn from. Waking either is
  -- the newly reachable path a third producer opens up, and only the abandoned chat is ours.
  --
  -- **Deliberately not `reservations.lua`'s `was_cancelled() or get_stop_reason() ~= nil`.** That
  -- gate defaults a new stop reason to "do not send", which is right for a reservation and wrong
  -- here: `error` is a stop reason, and a turn that failed *with subagents still outstanding* is
  -- the case most in need of waking — it is the shape `completion_notifier` also treats as
  -- must-deliver. So this asks only about the two stops that hand the chat back to a human, and a
  -- stop reason added later keeps waking until someone decides otherwise.
  if response._cancelled then
    return false
  end

  local Queue = require("vibing.application.chat.message_queue")
  local ok, err = Queue.enqueue_notice(bufnr, M.notice_body(unreported, recovered), false)
  if not ok then
    require("vibing.core.utils.notify").warn(
      string.format("Could not wake the chat about %d outstanding background subagent(s): %s", #unreported, err or "unknown"),
      "Subagent"
    )
    return false
  end

  -- Delivering is starting a turn, so it owes the concurrency limit the same as the other two
  -- producers do. `hold_for_capacity` is the registration `completion_notifier` keeps for exactly
  -- this shape — something queued before delivery was attempted — and it is what gets the notice
  -- retried when a slot frees. Without it the notice waits for an event this chat will never emit,
  -- since the turn that would have carried it is the one that just ended.
  if require("vibing.application.chat.concurrency").at_capacity() then
    require("vibing.application.chat.completion_notifier").hold_for_capacity(bufnr)
    return false
  end

  -- `flush` refuses a chat that is responding or has a draft on screen, and keeps the notice queued
  -- for the next completion event when it does. So the answer is whether a turn actually started —
  -- enqueuing succeeded either way, and reporting that as "woken" is how a chat that is still
  -- asleep gets counted as handled.
  return (Queue.flush(bufnr))
end

return M
