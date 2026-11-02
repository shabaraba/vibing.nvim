---A turn the resident CLI started by itself, shown in the chat as an ordinary one.
---
---When a background subagent finishes, the CLI answers its `task_notification` on its own. Before
---this module that turn never reached the buffer: the completion line and the model's report were
---decoded into the process's idle context and dropped, the chat stayed `idle`, and no orchestrator
---heard anything. The adapter now holds the turn's lines (`duplex_foreign_turn.lua`) and asks here.
---
---Adopting writes a `## Notice` naming what happened and opens a turn with `adopt_cli_turn`, which
---writes nothing to the CLI and replays what it held. Everything else — `## Assistant`, diffs,
---`### Tokens`, `VibingResponseDone`, the completion watchdog — is the ordinary send path's.
---
---**A chat that is still finishing its previous turn is waited for, not refused.** The CLI starts its
---own turn milliseconds after the `result` of the one before, while `_finish_turn` is still queued
---behind a `vim.schedule`; refusing there would drop exactly the common case. The wait ends on that
---chat's next `VibingResponseDone`, or gives up after `M.WAIT_MS` so held lines cannot pile up behind
---a turn that never finishes writing.
---
---**Whether the turn was adopted is read off the handle, never off the send's return value.** A send
---can report success and still stop short of the adapter (a session conflict, a non-resident
---transport). The adapter takes the held lines synchronously when it opens the turn, so anything
---still pending afterwards was not adopted and is handed back.
---@class Vibing.Application.CliInitiatedTurn
local M = {}

local Events = require("vibing.core.events")
local Notify = require("vibing.core.utils.notify")

---Shown when nothing was drawn between the turns — the completion landed inside the previous turn.
M.DEFAULT_NOTICE = "The CLI started a turn by itself (usually to report a background task that finished)."

---How long a chat still finishing its previous turn is waited for. That gap is normally a few ticks.
M.WAIT_MS = 10000

---@type table<number, {notice: string, handle: Vibing.CliTurnHandle}>
local waiting = {}

local subscribed = false

---@param notice string
---@return string
local function notice_text(notice)
  local trimmed = vim.trim(notice or "")
  if trimmed == "" then
    return M.DEFAULT_NOTICE
  end
  return trimmed
end

---@param bufnr number
---@param notice string
---@param handle Vibing.CliTurnHandle
---@return boolean settled false when the chat has to be waited for
local function try_adopt(bufnr, notice, handle)
  if not handle.pending() then
    return true
  end
  local chat_buf = vim.api.nvim_buf_is_valid(bufnr) and require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
  if not chat_buf then
    handle.discard()
    return true
  end
  if chat_buf:is_responding() or chat_buf:is_finishing_turn() then
    return false
  end
  if require("vibing.application.chat.message_queue").has_unsent_draft(chat_buf) then
    handle.discard()
    Notify.warn(
      "The CLI started a turn by itself, but this chat has an unsent message, so the turn is not shown. "
        .. "Its answer is still in the session.",
      "Chat"
    )
    return true
  end

  local ok, err = pcall(
    require("vibing.presentation.chat.modules.programmatic_sender").send,
    bufnr,
    notice_text(notice),
    nil,
    { kind = "Notice" },
    { adopt_cli_turn = true }
  )
  if handle.pending() then
    handle.discard()
    Notify.warn(
      string.format("Could not show the turn the CLI started by itself: %s", ok and "the chat refused it" or err),
      "Chat"
    )
  end
  return true
end

local function ensure_subscribed()
  if subscribed then
    return
  end
  subscribed = true
  local group = vim.api.nvim_create_augroup("VibingCliInitiatedTurn", { clear = true })
  Events.on_response_done(group, "CLI-initiated turn", function(bufnr)
    local entry = waiting[bufnr]
    if not entry then
      return
    end
    waiting[bufnr] = nil
    -- After the rest of `_finish_turn`'s subscribers: a queued delivery that starts a turn of its own
    -- first is fine — it flushes the held lines, and `pending()` is then false here.
    vim.schedule(function()
      M.adopt(bufnr, entry.notice, entry.handle)
    end)
  end)
end

---@param bufnr number|nil the chat whose process started the turn
---@param notice string what the idle context drew before the turn opened
---@param handle Vibing.CliTurnHandle
function M.adopt(bufnr, notice, handle)
  if not bufnr then
    handle.discard()
    return
  end
  if try_adopt(bufnr, notice, handle) then
    return
  end
  ensure_subscribed()
  local entry = { notice = notice, handle = handle }
  waiting[bufnr] = entry
  -- Not stopped when the wait ends some other way: `discard` does nothing to a turn that was already
  -- adopted or handed back, since the adapter no longer holds it.
  vim.fn.timer_start(M.WAIT_MS, function()
    if waiting[bufnr] == entry then
      waiting[bufnr] = nil
    end
    handle.discard()
  end)
end

---Test seam.
function M._reset()
  waiting = {}
end

return M
