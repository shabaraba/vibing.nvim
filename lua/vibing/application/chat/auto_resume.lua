--- Automatic continuation after a usage limit resets
---
--- When a turn is rejected because the plan's usage limit is exhausted, the CLI reports the
--- Unix timestamp at which the limit lifts. This module parks the chat, waits for that moment,
--- and sends a single continuation message so the conversation picks up where it stopped.
---
--- Deliberately conservative, because every path here spends tokens without a human present:
---   * opt-in (`agent.auto_resume_on_limit.enabled`, default false)
---   * a retry budget per limit hit (`max_retries`, default 1)
---   * never overwrites text the user has already typed into the pending `## User` section
---   * resumes are staggered so several parked chats don't all fire into the same fresh quota
---
--- @module vibing.application.chat.auto_resume

local PendingResume = require("vibing.infrastructure.storage.pending_resume")
local RateLimit = require("vibing.core.utils.rate_limit")

local M = {}

--- Refuse to schedule further out than this. A reset timestamp beyond it means the payload was
--- misread (wrong unit, wrong field), and a timer armed for months is worse than no feature.
local MAX_DELAY_SEC = 8 * 24 * 60 * 60

--- Active timers keyed by chat file path, so re-parking a chat replaces its timer instead of
--- stacking a second one that would double-send.
--- @type table<string, userdata>
local timers = {}

--- @return table
local function get_options()
  local config = require("vibing.config").get()
  local agent = config.agent or {}
  return agent.auto_resume_on_limit or {}
end

--- @param path string
local function stop_timer(path)
  local timer = timers[path]
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
    timers[path] = nil
  end
end

--- Seconds to wait before resuming a parked chat.
--- @param entry Vibing.PendingResume
--- @param opts table
--- @return number|nil delay_sec, string|nil reason_when_nil
local function compute_delay(entry, opts)
  local now = os.time()

  if not entry.resets_at then
    -- No reset timestamp anywhere in the payload. Rather than give up (which would make the
    -- whole feature dead weight if the undocumented event shape changes), fall back to a fixed
    -- delay — bounded in practice by max_retries.
    return opts.fallback_delay_sec or 300
  end

  local delay = entry.resets_at + (opts.grace_sec or 10) - now
  if delay > MAX_DELAY_SEC then
    return nil, string.format("reset time is %d days away; ignoring as implausible", math.floor(delay / 86400))
  end
  -- Already past (e.g. Neovim was closed across the whole window): resume promptly, not instantly,
  -- so startup has settled before a request goes out.
  return math.max(delay, 3)
end

--- Locate the ChatBuffer for a chat file, loading the file into a buffer if needed.
--- After a restart the chat is usually not open, so a resume that only worked for already-open
--- buffers would miss exactly the case persistence exists for.
--- @param chat_file_path string
--- @return table|nil chat_buffer, string|nil error
local function resolve_chat_buffer(chat_file_path)
  if vim.fn.filereadable(chat_file_path) == 0 then
    return nil, "chat file no longer exists"
  end

  local view = require("vibing.presentation.chat.view")

  local bufnr = vim.fn.bufnr(chat_file_path)
  if bufnr == -1 then
    bufnr = vim.fn.bufadd(chat_file_path)
  end
  if bufnr == 0 or bufnr == -1 then
    return nil, "could not create a buffer for the chat file"
  end
  vim.fn.bufload(bufnr)

  local chat_buf = view.get_chat_buffer(bufnr)
  if not chat_buf then
    local ok, attached = pcall(view.attach_to_buffer, bufnr, chat_file_path)
    if not ok or not attached then
      return nil, "could not attach the chat buffer"
    end
    chat_buf = attached
  end

  return chat_buf, nil
end

--- Drop the trailing empty `## User` section left behind by the failed turn, so the continuation
--- doesn't land under a second, orphaned header.
--- @param bufnr number
local function trim_empty_trailing_user_section(bufnr)
  local Timestamp = require("vibing.core.utils.timestamp")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local header_idx = nil
  for i = #lines, 1, -1 do
    if Timestamp.is_header(lines[i]) then
      header_idx = i
      break
    end
  end
  if not header_idx or Timestamp.extract_role(lines[header_idx]) ~= "user" then
    return
  end

  for i = header_idx + 1, #lines do
    if vim.trim(lines[i]) ~= "" then
      return -- section has content; leave it alone
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, header_idx - 1, -1, false, {})
end

--- Send the continuation message for a parked chat.
--- @param chat_file_path string
--- @param entry Vibing.PendingResume
local function fire(chat_file_path, entry)
  stop_timer(chat_file_path)

  local opts = get_options()
  if not opts.enabled then
    return
  end

  -- Re-read the store: the user may have cancelled, or answered the chat manually, between
  -- scheduling and now.
  local current = PendingResume.get(chat_file_path)
  if not current then
    return
  end

  -- Defence in depth. on_rate_limited() is the usual budget gate, but a resume can also reach
  -- here straight from restore(), which never consults it.
  if (current.retry_count or 0) >= (opts.max_retries or 1) then
    PendingResume.remove(chat_file_path)
    return
  end

  local chat_buf, err = resolve_chat_buffer(chat_file_path)
  if not chat_buf then
    PendingResume.remove(chat_file_path)
    vim.notify(
      string.format("[vibing] Auto-resume skipped for %s: %s", vim.fn.fnamemodify(chat_file_path, ":t"), err),
      vim.log.levels.WARN
    )
    return
  end

  if chat_buf:is_sending() then
    PendingResume.remove(chat_file_path)
    return
  end

  -- The user typed something into the pending section while the chat was parked. Their message
  -- is the one that should be sent, by them — not silently prefixed by ours.
  local typed = chat_buf:extract_user_message()
  if typed and vim.trim(typed) ~= "" then
    PendingResume.remove(chat_file_path)
    vim.notify(
      string.format(
        "[vibing] Auto-resume skipped for %s: an unsent message is waiting in the chat",
        vim.fn.fnamemodify(chat_file_path, ":t")
      ),
      vim.log.levels.INFO
    )
    return
  end

  -- Mark the request in flight *before* sending. If Neovim dies between here and the response,
  -- restore() must not treat this entry as still-waiting and send a second automatic request —
  -- the retry budget is only consulted when a limit is observed, not when a timer fires.
  current.retry_count = (current.retry_count or 0) + 1
  current.state = "in_flight"
  PendingResume.put(current)

  local bufnr = chat_buf:get_buffer()
  trim_empty_trailing_user_section(bufnr)

  local prompt = opts.prompt or "Continue from where you left off."
  local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
  local ok, send_err = pcall(ProgrammaticSender.send, bufnr, prompt)
  if not ok then
    PendingResume.remove(chat_file_path)
    vim.notify("[vibing] Auto-resume failed: " .. tostring(send_err), vim.log.levels.WARN)
    return
  end

  vim.notify(
    string.format("[vibing] Usage limit reset - resumed %s", vim.fn.fnamemodify(chat_file_path, ":t")),
    vim.log.levels.INFO
  )
end

--- Arm a timer for a parked chat.
--- Several chats parked on the same window all fire at once, which is deliberate: a reset hands
--- back a full quota, and vibing.nvim already runs concurrent chats during normal use.
--- @param entry Vibing.PendingResume
--- @param opts table
local function schedule(entry, opts)
  local path = entry.chat_file_path
  stop_timer(path)

  local delay_sec, reason = compute_delay(entry, opts)
  if not delay_sec then
    PendingResume.remove(path)
    vim.notify("[vibing] Auto-resume not scheduled: " .. tostring(reason), vim.log.levels.WARN)
    return
  end

  local delay_ms = delay_sec * 1000
  local timer = vim.loop.new_timer()
  if not timer then
    vim.notify("[vibing] Auto-resume not scheduled: no timer available", vim.log.levels.WARN)
    return
  end
  timers[path] = timer
  timer:start(
    delay_ms,
    0,
    vim.schedule_wrap(function()
      fire(path, entry)
    end)
  )

  vim.notify(
    string.format(
      "[vibing] Usage limit hit - %s will resume in %s",
      vim.fn.fnamemodify(path, ":t"),
      M.format_duration(math.floor(delay_ms / 1000))
    ),
    vim.log.levels.INFO
  )
end

--- Format a second count as a short human-readable duration
--- @param seconds number
--- @return string
function M.format_duration(seconds)
  if seconds < 60 then
    return seconds .. "s"
  end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then
    return minutes .. "m"
  end
  return string.format("%dh%02dm", math.floor(minutes / 60), minutes % 60)
end

--- Called when a response comes back rejected by a usage limit.
--- @param chat_file_path string|nil
--- @param info Vibing.RateLimitInfo
function M.on_rate_limited(chat_file_path, info)
  local opts = get_options()

  if not chat_file_path or chat_file_path == "" then
    return
  end

  if not opts.enabled then
    vim.notify(
      "[vibing] Usage limit reached (" .. RateLimit.describe(info) .. ")",
      vim.log.levels.WARN
    )
    return
  end

  local existing = PendingResume.get(chat_file_path)
  local retry_count = existing and existing.retry_count or 0
  local max_retries = opts.max_retries or 1

  if retry_count >= max_retries then
    PendingResume.remove(chat_file_path)
    vim.notify(
      string.format(
        "[vibing] Usage limit reached again after %d auto-resume(s) - giving up on %s",
        retry_count,
        vim.fn.fnamemodify(chat_file_path, ":t")
      ),
      vim.log.levels.WARN
    )
    return
  end

  local entry = {
    chat_file_path = chat_file_path,
    resets_at = info.resets_at,
    limit_type = info.limit_type,
    retry_count = retry_count,
    recorded_at = os.time(),
    state = "waiting",
  }
  PendingResume.put(entry)
  schedule(entry, opts)
end

--- Called when a chat completes without hitting a limit, clearing its retry budget.
--- @param chat_file_path string|nil
function M.on_success(chat_file_path)
  if not chat_file_path or chat_file_path == "" then
    return
  end
  if not PendingResume.get(chat_file_path) then
    return
  end
  stop_timer(chat_file_path)
  PendingResume.remove(chat_file_path)
end

--- Cancel a pending resume (user-initiated)
--- @param chat_file_path string|nil When nil, cancels every pending resume
--- @return number cancelled_count
function M.cancel(chat_file_path)
  if chat_file_path then
    stop_timer(chat_file_path)
    local existed = PendingResume.get(chat_file_path) ~= nil
    PendingResume.remove(chat_file_path)
    return existed and 1 or 0
  end

  local entries = PendingResume.load()
  local count = 0
  for path, _ in pairs(entries) do
    stop_timer(path)
    count = count + 1
  end
  PendingResume.clear()
  return count
end

--- List pending resumes (for :VibingPendingResumes)
--- @return Vibing.PendingResume[]
function M.list()
  local out = {}
  for _, entry in pairs(PendingResume.load()) do
    table.insert(out, entry)
  end
  table.sort(out, function(a, b)
    return (a.resets_at or math.huge) < (b.resets_at or math.huge)
  end)
  return out
end

--- Re-arm timers for chats parked before Neovim was restarted.
--- Called once at startup; safe to call again (each chat's timer is replaced, not stacked).
function M.restore()
  local opts = get_options()
  if not opts.enabled then
    return
  end

  for _, entry in pairs(PendingResume.load()) do
    -- Only re-arm chats still waiting on a reset. An "in_flight" entry was already sent by a
    -- previous session whose outcome we never saw; re-sending it would spend a second request
    -- outside the retry budget. The entry is kept (not deleted) so its retry_count still counts
    -- against max_retries if that chat hits the limit again.
    if entry.chat_file_path and (entry.state or "waiting") == "waiting" then
      schedule(entry, opts)
    end
  end
end

return M
