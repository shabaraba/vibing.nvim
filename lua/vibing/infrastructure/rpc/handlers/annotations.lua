--- Inline review notes, shown next to the code they are about instead of only in the chat.
---
--- Annotations are extmark virt_lines: the file is never touched and `modified` never gets set.
--- They are deliberately not persisted — a review is read once and then dismissed, so unloading
--- the buffer taking them with it is the intended lifetime, not a gap.
--- @module vibing.infrastructure.rpc.handlers.annotations

local M = {}

local resolve_bufnr = require("vibing.infrastructure.rpc.handlers.bufnr").resolve

local NAMESPACE = vim.api.nvim_create_namespace("vibing_annotations")

--- Marker down the left of every annotation line, so a note can't be mistaken for real code.
local MARKER = "┃ "

--- @type table<string, string>
local SEVERITY_GROUPS = {
  info = "VibingAnnotationInfo",
  warn = "VibingAnnotationWarn",
  error = "VibingAnnotationError",
}

--- `default = true` so a user's own `hi VibingAnnotationWarn ...` wins. Linked to the diagnostic
--- virtual-text groups because that is what a reader already reads as "a note about this line".
local function ensure_highlight_groups()
  vim.api.nvim_set_hl(0, "VibingAnnotationInfo", { link = "DiagnosticVirtualTextInfo", default = true })
  vim.api.nvim_set_hl(0, "VibingAnnotationWarn", { link = "DiagnosticVirtualTextWarn", default = true })
  vim.api.nvim_set_hl(0, "VibingAnnotationError", { link = "DiagnosticVirtualTextError", default = true })
end

--- Attach a note to a line.
--- @param params table
---   - bufnr (number): target buffer, 0 for current (required)
---   - line (number): 1-indexed line to annotate (required)
---   - text (string): note body; newlines become separate virtual lines (required)
---   - severity (string): "info" | "warn" | "error" (defaults to "info")
--- @return table
function M.annotate(params)
  params = params or {}

  local bufnr = resolve_bufnr(params.bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("Invalid buffer: " .. tostring(bufnr))
  end

  local line = params.line
  if type(line) ~= "number" then
    error("Missing line parameter")
  end

  local text = params.text
  if type(text) ~= "string" or text == "" then
    error("Missing text parameter")
  end

  local severity = params.severity
  local hl_group = SEVERITY_GROUPS[severity]
  if not hl_group then
    severity = "info"
    hl_group = SEVERITY_GROUPS.info
  end

  -- Same reasoning as highlight_range: the model works from search results that go stale by a
  -- line or two, so land the note near the right place rather than refusing to place it.
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  line = math.max(1, math.min(line, line_count))

  ensure_highlight_groups()

  local virt_lines = {}
  for _, chunk in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(virt_lines, { { MARKER .. chunk, hl_group } })
  end

  local id = vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, line - 1, 0, {
    virt_lines = virt_lines,
  })

  return {
    success = true,
    bufnr = bufnr,
    line = line,
    severity = severity,
    extmark_id = id,
  }
end

--- Drop annotations.
--- @param params table - bufnr (number): target buffer; omit to clear every buffer
--- @return table
function M.clear_annotations(params)
  params = params or {}

  local cleared = {}
  local targets
  if params.bufnr == nil then
    targets = vim.api.nvim_list_bufs()
  else
    targets = { resolve_bufnr(params.bufnr) }
  end

  for _, bufnr in ipairs(targets) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      -- Only report buffers that actually had something: cleared_buffers is part of the tool's
      -- return value, so listing untouched buffers would mislead the caller. limit = 1 because
      -- this only needs to know whether any mark exists, not fetch them all.
      local existing = vim.api.nvim_buf_get_extmarks(bufnr, NAMESPACE, 0, -1, { limit = 1 })
      if #existing > 0 then
        vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
        table.insert(cleared, bufnr)
      end
    end
  end

  return { success = true, cleared_buffers = cleared }
end

--- @private Exposed for tests.
M._namespace = NAMESPACE

return M
