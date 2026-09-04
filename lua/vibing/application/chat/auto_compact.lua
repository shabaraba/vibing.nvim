--- Opt-in `/compact` once a chat has grown past a threshold.
---
--- `/compact` is the Claude CLI's own command and it reaches the CLI from a chat because an
--- unrecognised slash command falls through as prompt text. It replaces the conversation with a
--- summary, which is the one thing that actually shrinks what every later request re-reads --
--- the CLI's automatic compaction fires near the model's context ceiling (~930k), long after the
--- expensive requests have been paid for.
---
--- **The compaction is inserted before the next manual send, not after the turn that crossed the
--- threshold.** Compaction costs a full prefix rewrite on the turn that follows it (measured at
--- 79,783 tokens of new cache), so a reader who crosses the threshold and then moves to a fresh
--- chat would have paid it for nothing. Waiting until they type again is what makes the spend
--- follow the intent to keep going.
---
--- Deliberately narrow, for the same reason `auto_resume` is -- every path here spends tokens on
--- a turn the user did not ask for:
---
---   * opt-in (`agent.token_usage.auto_compact.enabled`, default false)
---   * **manual sends only.** Never a scheduled request, an auto-resume, or a message delivered
---     from another chat. That is why the hook is on the `<CR>` keymap rather than inside
---     `ChatBuffer:send_message()`, which every one of those paths also goes through. It runs
---     inside `cache_expiry_prompt.guard`'s callback, so a send the user calls off at that
---     prompt does not leave a rewritten `/compact` behind.
---   * **claude only.** On the other backends `/compact` is not a command, so it would arrive as
---     a line of prose and be answered as one.
---   * **at most every other manual send.** If a compaction fails to shrink the conversation,
---     the cooldown is what stops every subsequent send from costing two turns.
---
--- @module vibing.application.chat.auto_compact

local M = {}

local AUGROUP = "VibingAutoCompact"

--- Chats whose in-flight turn is an inserted compaction, mapped to the message that still has to
--- be sent when it finishes.
---
--- The body is held here rather than handed to `ChatBuffer:set_pending_user_text`, which was the
--- obvious seam and the wrong one: `addUserSection` renders the pending text, the question list
--- and the approval prompt into the **same** unsent section. A compaction that somehow stopped
--- for an approval would leave the user looking at their own message concatenated with the option
--- list, and `<CR>` on that parses as neither.
--- @type table<number, string>
local pending = {}

--- Chats that just ran an inserted compaction. Consumed by the next manual send.
--- @type table<number, boolean>
local cooldown = {}

--- @return table
local function options()
  local config = require("vibing.config").get()
  local token_usage = config.agent and config.agent.token_usage or {}
  return token_usage.auto_compact or {}
end

--- The message that gets sent as a turn.
--- @param focus string|nil What the summary should keep
--- @return string
function M.compact_prompt(focus)
  if type(focus) == "string" and vim.trim(focus) ~= "" then
    return "/compact " .. vim.trim(focus)
  end
  return "/compact"
end

--- Replace the body of the trailing unsent section, keeping its header.
---
--- The header is kept rather than rebuilt because it carries the section kind and sender
--- (`## Request <!-- unsent … from … -->`); writing `## User` back would erase who the turn is
--- for. Returns false when there is no unsent section to rewrite, which the callers treat as
--- "leave this send alone" rather than as an error.
--- @param bufnr number
--- @param text string
--- @return boolean rewritten
local function rewrite_unsent_body(bufnr, text)
  local Timestamp = require("vibing.core.utils.timestamp")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local header_idx
  for i = #lines, 1, -1 do
    if Timestamp.is_header(lines[i]) then
      header_idx = i
      break
    end
  end
  if not header_idx or not Timestamp.is_unsent_header(lines[header_idx]) then
    return false
  end

  local body = vim.split(text, "\n", { plain = true })
  table.insert(body, 1, "")
  table.insert(body, "")
  vim.api.nvim_buf_set_lines(bufnr, header_idx, -1, false, body)
  return true
end

M._rewrite_unsent_body = rewrite_unsent_body

--- Whether this chat's next turn should be a compaction.
---
--- Split out from `before_manual_send` so the rules are testable without a live chat buffer and
--- without a `/compact` turn actually going out.
--- The message-shaped exclusions (slash commands, approval answers) are **not** here: they are
--- `ChatBuffer:can_defer_send`, which the caller consults. This is the third interception on the
--- `<CR>` path and the third to need exactly that judgement, so re-deriving it here is how one of
--- the three silently stops excluding an approval answer.
--- @param opts table `agent.token_usage.auto_compact`
--- @param agent string The backend this chat resolves to
--- @param context number|nil The last reported context size, if any
--- @param on_cooldown boolean Whether the previous manual send already inserted a compaction
--- @return boolean
function M.should_compact(opts, agent, context, on_cooldown)
  if not opts.enabled or on_cooldown or agent ~= "claude" then
    return false
  end

  local TokenUsage = require("vibing.core.utils.token_usage")
  local at = tonumber(opts.at) or TokenUsage.DEFAULT_AUTO_COMPACT_AT
  -- `at <= 0` reads as "off" rather than "always", matching how `warn_context = 0` silences the
  -- warning instead of firing it on every turn.
  if at <= 0 or not context then
    return false
  end

  return context >= at
end

--- Whether this chat's backend has a usage limit recorded as still in force.
---
--- Read the same way `_try_schedule_instead_of_send` reads it -- per project directory, scoped to
--- the backend this chat resolves to -- since a codex limit is no reason to hold back a claude
--- chat's compaction.
--- @param bufnr number
--- @param agent string
--- @return boolean
function M._limit_active(bufnr, agent)
  local chat_file_path = vim.api.nvim_buf_get_name(bufnr)
  if chat_file_path == "" then
    return false
  end
  local LimitState = require("vibing.infrastructure.storage.limit_state")
  local ok, state = pcall(LimitState.get_active, vim.fn.fnamemodify(chat_file_path, ":h"), agent)
  return ok and state ~= nil
end

--- Turn a manual send into a compaction, parking the user's message for the turn after it.
---
--- Called from the chat's `<CR>` keymap **before** `ChatBuffer:send_message()`, so the ordinary
--- send path sees only a buffer whose unsent section says `/compact`. Nothing about sending
--- changes; what changes is what is sitting there to be sent.
--- @param chat_buf table
--- @return boolean inserted Whether the send about to happen is now a compaction
function M.before_manual_send(chat_buf)
  local bufnr = chat_buf:get_buffer()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  -- This runs on every `<CR>` in every chat, and the feature is off by default, so the disabled
  -- path must not touch the buffer. Everything below reads it: `extract_user_message` and
  -- `parse_frontmatter` each scan it, and `read_last_turn` copies the whole thing into Lua.
  local opts = options()
  if not opts.enabled then
    return false
  end

  local body = chat_buf:extract_user_message()
  if not body or vim.trim(body) == "" or not chat_buf:can_defer_send(body) then
    return false
  end

  -- The cooldown is spent only by the kind of send it exists to skip. Clearing it above this
  -- guard let an empty `<CR>`, a `/model` or an approval answer consume it, and the next real
  -- message would then compact again off the compaction turn's own `### Tokens` -- which reports
  -- the size of the request that carried the whole conversation, i.e. the pre-compaction figure.
  local on_cooldown = cooldown[bufnr] == true
  cooldown[bufnr] = nil

  local Modes = require("vibing.core.constants.modes")
  local TokenUsage = require("vibing.core.utils.token_usage")
  local config = require("vibing.config").get()
  local agent = Modes.resolve_agent(chat_buf:parse_frontmatter(), config)

  -- The chat's size is read the same way the cache gate reads it, and from the same helper: the
  -- `### Tokens` section of the **last assistant turn only**. Scanning the whole buffer for the
  -- last heading is the trap `read_last_turn` exists to avoid -- `parse_context`'s humanized
  -- fallback matches any line starting `context <number>`, which ordinary prose produces.
  local _, context = require("vibing.application.chat.cache_expiry").read_last_turn(bufnr)

  if not M.should_compact(opts, agent, context, on_cooldown) then
    return false
  end

  -- Not while the backend's usage limit is on record. `ChatBuffer:_try_schedule_instead_of_send`
  -- parks a message rather than sending it, but it exempts slash commands, so the `/compact`
  -- would go out and be rejected -- and `_reschedule_rejected_message` then writes *its* text
  -- back into the unsent section and arms a timer to send it. Two writers would be aiming at one
  -- section. A limit is also the worst moment to spend a turn on compaction.
  if M._limit_active(bufnr, agent) then
    return false
  end

  if not rewrite_unsent_body(bufnr, M.compact_prompt(opts.focus)) then
    return false
  end

  pending[bufnr] = body
  cooldown[bufnr] = true

  vim.notify(
    string.format(
      "[vibing] Context is %s - running /compact first, then sending your message.",
      TokenUsage.humanize(context)
    ),
    vim.log.levels.INFO
  )
  return true
end

--- Whether a finished turn is the moment to release the parked message.
---
--- `wait` keeps the message parked: the chat stopped on something only the user can clear, and its
--- unsent section is occupied by the prompt they have to answer. Writing the message in there
--- would concatenate the two. The parked entry survives, so answering the prompt ends another
--- turn and brings this decision round again.
--- @param stop_reason string|nil `ChatBuffer:get_stop_reason()`
--- @return "send"|"wait"
function M.resume_decision(stop_reason)
  if stop_reason == "waiting_approval" or stop_reason == "asked_question" then
    return "wait"
  end
  -- Anything else releases it, `error` included. A compaction that failed is a reason to have
  -- wasted a turn, not a reason to swallow the message the user actually typed.
  return "send"
end

--- Write the parked message into the chat and send it, once the compaction finishes.
--- @param bufnr number
function M.on_response_done(bufnr)
  local body = pending[bufnr]
  if not body then
    return
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    pending[bufnr] = nil
    return
  end

  local chat_buf = require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
  if not chat_buf then
    pending[bufnr] = nil
    return
  end

  if M.resume_decision(chat_buf:get_stop_reason()) == "wait" then
    vim.notify(
      "[vibing] /compact finished but the chat needs an answer first; your message goes out after it.",
      vim.log.levels.WARN
    )
    return
  end

  pending[bufnr] = nil

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) or chat_buf:is_sending() or chat_buf:is_responding() then
      return
    end
    if not rewrite_unsent_body(bufnr, body) then
      vim.notify("[vibing] /compact finished but your message could not be written back", vim.log.levels.WARN)
      return
    end
    -- `ChatBuffer:send_message()` rather than the keymap's wrapper: this send must not be
    -- eligible for another compaction.
    pcall(function()
      chat_buf:send_message()
    end)
  end)
end

--- `:VibingCompact [focus]`
---
--- Refuses while an unsent message is waiting rather than parking it the way the automatic path
--- does. The automatic path exists because the user asked to send *that message*; this command
--- was typed on its own and should mean exactly one turn.
--- @param focus string|nil
function M.compact_now(focus)
  local notify = require("vibing.core.utils.notify")
  local chat_buf = require("vibing.presentation.chat.view").get_current()
  if not chat_buf then
    notify.warn("Not in a chat buffer")
    return
  end

  local Modes = require("vibing.core.constants.modes")
  local agent = Modes.resolve_agent(chat_buf:parse_frontmatter(), require("vibing.config").get())
  if agent ~= "claude" then
    notify.warn(string.format("/compact is a Claude CLI command; this chat runs on '%s'", agent))
    return
  end

  local body = chat_buf:extract_user_message()
  if body and vim.trim(body) ~= "" then
    notify.warn("Send or clear the unsent message first - :VibingCompact runs a turn on its own")
    return
  end

  local bufnr = chat_buf:get_buffer()
  if not rewrite_unsent_body(bufnr, M.compact_prompt(focus)) then
    notify.warn("No unsent section to write into")
    return
  end

  -- Take the cooldown too. A compaction turn's own `### Tokens` reports the context of the
  -- request that *carried* the conversation -- the pre-compaction size -- so the last section in
  -- the buffer still reads as large afterwards. On the automatic path the user's message runs
  -- next and overwrites it with the smaller number; this command ends there, so without the
  -- cooldown the very next `<CR>` would compact a chat that was just compacted.
  cooldown[bufnr] = true

  -- A manual send, so it resets the orchestration round-trip counter the same way `<CR>` does.
  -- Skipping it would let a notification chain run out of budget early.
  require("vibing.application.chat.completion_notifier").on_manual_send(bufnr)
  chat_buf:send_message()
end

--- @param bufnr number
function M.forget(bufnr)
  pending[bufnr] = nil
  cooldown[bufnr] = nil
end

--- Subscribe to turn completion.
---
--- `enabled` is deliberately not read here, matching `completion_notifier.setup()`: the event
--- fires regardless, the subscriber decides, and a setting changed mid-session takes effect
--- without a reload. With the feature off this costs one table lookup per turn.
function M.setup()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "VibingResponseDone",
    callback = function(event)
      local bufnr = event.data and event.data.bufnr
      if type(bufnr) == "number" then
        M.on_response_done(bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(event)
      M.forget(event.buf)
    end,
  })
end

return M
