---Slice a buffer's lines down to the window a caller asked for, for a buffer too large to read
---in full (#694). One primitive so `nvim_get_buffer` and the orchestration notifier (#693) cannot
---drift on what "the tail" or "the last section" means.
---@class Vibing.Domain.Chat.BufferWindow
local M = {}

local Timestamp = require("vibing.core.utils.timestamp")

---1-indexed index of the last `## <Kind> <!-- ... -->` header in `lines`, scanning from the end,
---or nil if `lines` has none. Exported (unlike the section-start helper below, which folds "none"
---into 1) so a caller reading a buffer incrementally — a suffix chunk, say — can tell "no header
---in what I've read so far" apart from "the header is the first line I read", and keep reading
---further back only in the first case (`infrastructure/rpc/handlers/buffer.lua`'s chunked scan).
---@param lines string[]
---@return integer?
function M.find_last_header(lines)
  for i = #lines, 1, -1 do
    if Timestamp.is_header(lines[i]) then
      return i
    end
  end
  return nil
end

---1-indexed start of the last section, or 1 when `lines` has no header at all — the whole thing
---is one section.
---@param lines string[]
---@return integer
local function last_section_start(lines)
  return M.find_last_header(lines) or 1
end

---Normalize a `tail_lines` argument to a non-negative integer, or nil for "not given"/unusable.
---
---The MCP layer already rejects a negative or fractional value before it reaches Neovim
---(`validatePositiveInteger` in `schema.ts`), but this primitive exists precisely so a future
---direct Lua caller (#693) can skip that layer — so it has to defend the same ground itself
---rather than silently misbehaving when handed a negative or fractional number (a caller asking
---for a fractional tail is a bug in the caller, and a floor makes it a harmless one).
---@param value any
---@return integer?
local function normalize_tail_lines(value)
  if type(value) ~= "number" then
    return nil
  end
  return math.max(0, math.floor(value))
end

M.normalize_tail_lines = normalize_tail_lines

---@class Vibing.Domain.Chat.BufferWindow.Opts
---@field tail_lines number? Keep only the last N lines (applied after `last_section`, if both given).
---@field last_section boolean? Keep only the buffer's last `## ...` section.

---Compute the windowed lines plus the buffer's real total, so a caller that only sees the tail
---still learns the overall scale (the point of returning `total_lines` at all).
---@param lines string[]
---@param opts Vibing.Domain.Chat.BufferWindow.Opts?
---@return string[] windowed
---@return integer total_lines
function M.slice(lines, opts)
  local total_lines = #lines
  opts = opts or {}
  local tail_lines = normalize_tail_lines(opts.tail_lines)

  local start = opts.last_section and last_section_start(lines) or 1
  local section_length = total_lines - start + 1
  if tail_lines and tail_lines < section_length then
    start = total_lines - tail_lines + 1
  end

  local windowed = start == 1 and lines or vim.list_slice(lines, start, total_lines)
  return windowed, total_lines
end

return M
