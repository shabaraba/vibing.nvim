--- Project-local system prompt (`.vibing/system-prompt.md`)
---
--- The file is created empty on chat creation so users have somewhere to put
--- project-specific instructions; its contents are appended to the CLI's
--- `--append-system-prompt` on every non-lightweight request.
--- @module vibing.core.utils.project_system_prompt

local Fs = require("vibing.core.utils.fs")

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
    Fs.ensure_dir(project_root .. "/.vibing")
    vim.fn.writefile({}, prompt_file)
  end
end

--- Cut `s` down to at most `max_bytes` without splitting a UTF-8 character:
--- walk back off any continuation bytes (`0b10xxxxxx`) left at the boundary.
--- @param s string
--- @param max_bytes number
--- @return string
local function cut_at_utf8_boundary(s, max_bytes)
  local cut = max_bytes
  while cut > 0 do
    local next_byte = s:byte(cut + 1)
    -- nil (nothing dropped), ASCII, or a lead byte all mean `cut` is a boundary
    if not next_byte or next_byte < 0x80 or next_byte >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return s:sub(1, cut)
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
    content = cut_at_utf8_boundary(content, MAX_BYTES)
    require("vibing.core.utils.notify").warn(
      string.format(".vibing/system-prompt.md exceeds %d bytes - truncated", MAX_BYTES),
      "Config"
    )
  end

  return content
end

--- Read the prompt that applies to a request running in `cwd`.
---
--- A chat with a `working_dir` (a worktree under `.vibing/worktrees/<branch>/`) runs
--- the CLI there, so its own `.vibing/system-prompt.md` wins when it has content.
--- Worktrees are separate checkouts and `.vibing/` is git-ignored, so that file
--- usually doesn't exist there — fall back to the root Neovim was started in, which
--- is where `ensure()` creates the file and where users actually edit it.
--- @param cwd string|nil working directory of the request (`opts.cwd`)
--- @return string|nil content
function M.read_for_cwd(cwd)
  local nvim_root = vim.fn.getcwd()
  if cwd and cwd ~= "" and cwd ~= nvim_root then
    local from_cwd = M.read(cwd)
    if from_cwd then
      return from_cwd
    end
  end
  return M.read(nvim_root)
end

return M
