--- Temporary range highlighting, so the agent can point at code instead of describing where it is.
--- @module vibing.infrastructure.rpc.handlers.highlight

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("vibing_highlight")

--- Pending auto-clear timers, keyed by buffer. A second call to the same buffer has to stop the
--- first one, or the earlier timer fires mid-way through the new highlight and clears it early.
--- @type table<number, uv.uv_timer_t>
local clear_timers = {}

local DEFAULT_DURATION_MS = 3000

--- `default = true` so `hi VibingHighlight ...` in a user's config wins. Visual is the closest
--- built-in in meaning: "this is the bit being pointed at".
local function ensure_highlight_group()
  vim.api.nvim_set_hl(0, "VibingHighlight", { link = "Visual", default = true })
end

--- @param bufnr number
local function clear_marks(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
  end
end

--- Cancel a pending auto-clear and drop the marks. Only for the early paths — the timer's own
--- callback must not come through here, because vim.defer_fn closes the handle after the callback
--- returns and closing it again from inside errors.
--- @param bufnr number
local function clear(bufnr)
  local timer = clear_timers[bufnr]
  clear_timers[bufnr] = nil
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  clear_marks(bufnr)
end

--- @param bufnr any
--- @return number
local function resolve_bufnr(bufnr)
  if type(bufnr) ~= "number" then
    error("Missing bufnr parameter")
  end
  if bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

--- Highlight a line range, then take it away again.
--- @param params table
---   - bufnr (number): target buffer, 0 for current (required)
---   - start_line (number): 1-indexed first line (required)
---   - end_line (number): 1-indexed last line, inclusive (defaults to start_line)
---   - duration_ms (number): clear after this many ms; 0 keeps it until the next call
--- @return table
function M.highlight_range(params)
  params = params or {}

  local start_line = params.start_line
  if type(start_line) ~= "number" then
    error("Missing start_line parameter")
  end

  local bufnr = resolve_bufnr(params.bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("Invalid buffer: " .. tostring(bufnr))
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local end_line = params.end_line or start_line
  -- Clamp rather than error: the agent is working from search results that may be a few lines
  -- stale, and pointing at roughly the right place beats refusing to point at all.
  start_line = math.max(1, math.min(start_line, line_count))
  end_line = math.max(start_line, math.min(end_line, line_count))

  -- A negative duration would otherwise fall through the `> 0` check below and read as "keep
  -- forever", which is what 0 means. Treat it as unset rather than as a second way to say 0.
  local duration_ms = params.duration_ms
  if type(duration_ms) ~= "number" or duration_ms < 0 then
    duration_ms = DEFAULT_DURATION_MS
  end

  ensure_highlight_group()
  clear(bufnr)

  local last = vim.api.nvim_buf_get_lines(bufnr, end_line - 1, end_line, false)[1] or ""
  vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, start_line - 1, 0, {
    end_row = end_line - 1,
    end_col = #last,
    hl_group = "VibingHighlight",
  })

  if duration_ms > 0 then
    clear_timers[bufnr] = vim.defer_fn(function()
      clear_timers[bufnr] = nil
      clear_marks(bufnr)
    end, duration_ms)
  end

  return {
    success = true,
    bufnr = bufnr,
    start_line = start_line,
    end_line = end_line,
    duration_ms = duration_ms,
  }
end

--- Drop the highlight before its timer runs out.
---
--- This is what makes `duration_ms = 0` usable: without it, a highlight asked to stay could only
--- be taken away by highlighting something else.
--- @param params table - bufnr (number): target buffer, 0 for current (required)
--- @return table
function M.clear_highlight(params)
  params = params or {}
  local bufnr = resolve_bufnr(params.bufnr)

  clear(bufnr)
  return { success = true, bufnr = bufnr }
end

--- @private Exposed for tests.
M._namespace = NAMESPACE

return M
