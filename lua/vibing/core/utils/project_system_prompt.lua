--- Project-local system prompt (`.vibing/system-prompt.md`)
---
--- The file is created empty on chat creation so users have somewhere to put
--- project-specific instructions; its contents are appended to the CLI's
--- `--append-system-prompt` on every non-lightweight request.
--- @module vibing.core.utils.project_system_prompt

local M = {}

--- 8 KiB. Large enough for real instructions, small enough that a stray paste
--- of a log file doesn't silently balloon every request's system prompt.
local MAX_BYTES = 8 * 1024

--- @param project_root string
--- @return string path
function M.path(project_root)
  return project_root .. "/.vibing/system-prompt.md"
end

--- Create an empty `.vibing/system-prompt.md` if it doesn't exist yet.
--- @param project_root string
function M.ensure(project_root)
  local prompt_file = M.path(project_root)
  if vim.fn.filereadable(prompt_file) == 0 then
    vim.fn.mkdir(project_root .. "/.vibing", "p")
    vim.fn.writefile({}, prompt_file)
  end
end

--- Read the project-local system prompt.
--- Returns nil when the file is missing, unreadable, empty, or whitespace-only,
--- so callers can skip it without special-casing. Content over MAX_BYTES is
--- truncated rather than rejected, so an oversized file degrades instead of
--- silently dropping the user's instructions.
--- @param project_root string
--- @return string|nil content
function M.read(project_root)
  local prompt_file = M.path(project_root)
  if vim.fn.filereadable(prompt_file) ~= 1 then
    return nil
  end

  local ok, lines = pcall(vim.fn.readfile, prompt_file)
  if not ok or type(lines) ~= "table" then
    return nil
  end

  local content = vim.trim(table.concat(lines, "\n"))
  if content == "" then
    return nil
  end

  if #content > MAX_BYTES then
    content = content:sub(1, MAX_BYTES)
    require("vibing.core.utils.notify").warn(
      string.format(".vibing/system-prompt.md exceeds %d bytes - truncated", MAX_BYTES),
      "Config"
    )
  end

  return content
end

return M
