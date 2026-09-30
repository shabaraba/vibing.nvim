--- The third producer of "wake this chat".
---
--- A background subagent outlives the turn that launched it, and the CLI is supposed to deliver a
--- `task_notification` and start a new turn by itself. When it does not, nothing else will: the
--- process serving a turn dies with it (oneshot) or sits idle (duplex), and the only way to deliver
--- anything to a chat is to start a new turn on it. So a turn that ends with subagents still
--- outstanding leaves the chat unreachable until a human types into it — the user-visible symptom
--- being "the response just stopped" (#820).
---
--- **Two entry points, because the two transports learn this at different moments.** `M.wake` is the
--- end of a turn, which on oneshot is also the end of the process; `M.wake_orphaned` is a resident
--- process being reclaimed, which is the first moment duplex can say the same thing (#840). What they
--- share is the ledger being the signal and the notice being one turn. What the notice *says* is not
--- decided by which of them called: it turns on whether the subagents went down with the CLI, and one
--- reclaim route leaves them exactly as an ordinary exit does (`COPY`).
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
--- subscription graph keyed on a *pair* of chats, and this is a self-wake), and why no wake budget is
--- needed (one outstanding set cannot wake twice — on oneshot the ledger is per turn, on duplex it is
--- per process and the reclaim happens once): `handbook/features/chat-ui.md` → "A turn that ends with
--- subagents outstanding".
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

---The two notices, side by side, because the only difference between them is what they say.
---
---**The question is whether the subagents are still out there, and it is not the same as which
---producer called.** A background subagent runs *inside* the CLI, so a reclaim that killed that
---process took it with it: nothing is coming, and "go and collect them" would tell the model to wait
---for something that cannot arrive. But a CLI that simply *exited* — the oneshot transport's ordinary
---end of turn, and duplex's `exited` route — leaves the same state either way: the work may have
---finished with its notification dropped, and its transcript is on disk to collect. So the flag is
---`subagents_lost`, decided by `Vibing.DuplexReclaimVerdict`, never by which of the two entry points
---was used.
---
---Held as data rather than branched at each of the three places it shows up, so the two can be read
---and compared as wholes and the layout below stays variant-free.
local COPY = {
  alive = {
    headline = "This turn ended with %d background subagent(s) that never reported a completion. "
      .. "The CLI did not start a new turn for them, so this chat would not have run again.",
    still_owed = "Nothing recoverable yet for these — they may still be running:",
    instruction = "Collect their output before continuing (`TaskOutput`, or `SendMessage` with the "
      .. "agent id). If they are gone, say so and re-dispatch rather than waiting — nothing will wake "
      .. "this chat again on its own.",
  },
  lost = {
    headline = "The CLI process serving this chat was reclaimed with %d background subagent(s) that "
      .. "never reported a completion. They were running inside it, so they are gone, and nothing "
      .. "would have started another turn here.",
    still_owed = "Nothing was recoverable for these, and they will never report:",
    instruction = "Re-dispatch the ones whose work still matters, or say what was lost and carry on "
      .. "with what you have. Do not wait for them.",
  },
}

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
---@param subagents_lost boolean? the reclaim killed the CLI that was running them, so nothing is coming
---@return string
function M.notice_body(unreported, recovered, subagents_lost)
  local copy = subagents_lost and COPY.lost or COPY.alive
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

  local lines = { string.format(copy.headline, #unreported) }

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
    table.insert(lines, copy.still_owed)
    table.insert(lines, "")
    for _, entry in ipairs(still_owed) do
      table.insert(lines, string.format("- %s", name_of(entry)))
    end
    table.insert(lines, "")
    table.insert(lines, copy.instruction)
  else
    table.insert(lines, "")
    table.insert(lines, "Continue the task these were launched for.")
  end

  return table.concat(lines, "\n")
end

---Queue the notice and start the turn that carries it. Knows nothing about which route sent it —
---the count is for the warning and the body is already written.
---@param bufnr number|nil
---@param unreported Vibing.BackgroundTask[] non-empty. **Each entry point checks that, not this
---  function** — they have to, because they build `body` first, and `M.wake` runs on every turn in the
---  editor's life. A guard here as well would make one of the two provably dead: whichever ran second
---  could never be the one that returned, so no test could hold it in place.
---@param body string
---@return boolean woken
local function deliver(bufnr, unreported, body)
  -- A chat that was wiped while its turn ran has nowhere to be woken. Checked here rather than
  -- left to the queue: `flush` reports an invalid bufnr as "vanished without a BufDelete event",
  -- which is a real anomaly worth a warning and not what an ordinary closed chat is.
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return false
  end

  local Queue = require("vibing.application.chat.message_queue")
  local ok, err = Queue.enqueue_notice(bufnr, body, false)
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

  return deliver(bufnr, unreported, M.notice_body(unreported, response._recovered_subagents or {}, false))
end

---Wake the chat about background subagents that went down with the CLI process running them (#840).
---
---The duplex counterpart of `M.wake`. There is no response to read, because no turn ended: the
---process was reclaimed between turns, which is the only moment that transport can honestly say
---"nothing will report these" (`infrastructure/adapter/modules/duplex_stream.lua`). Which reclaim
---routes mean that — and which of them stay quiet — is `duplex_pool`'s `QUIET_RECLAIM`, so the
---`_cancelled` judgement `M.wake` makes here has already been made one layer down.
---@param bufnr number|nil
---@param unreported Vibing.BackgroundTask[]
---@param recovered Vibing.RecoveredSubagent[]
---@param subagents_lost boolean? whether the reclaim killed the CLI running them. Not "did a reclaim
---  happen" — `exited` is a reclaim that did not, and it leaves the state the turn-end route describes.
---@return boolean woken
function M.wake_orphaned(bufnr, unreported, recovered, subagents_lost)
  if #unreported == 0 then
    return false
  end
  return deliver(bufnr, unreported, M.notice_body(unreported, recovered or {}, subagents_lost))
end

return M
