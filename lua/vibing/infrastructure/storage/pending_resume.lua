--- Persistence for chats waiting on a usage-limit reset
---
--- A five-hour limit resets hours away and a weekly limit days away, so an in-memory timer is not
--- enough: Neovim will often be restarted in between. State lives in
--- `<project root>/.vibing/pending-resume.json` (gitignored like the rest of `.vibing/`) and is
--- reloaded on startup so a pending resume survives a restart.
---
--- @module vibing.infrastructure.storage.pending_resume

local Git = require("vibing.core.utils.git")

local M = {}

--- @class Vibing.PendingResume
--- @field chat_file_path string Absolute path of the chat file to resume
--- @field resets_at number|nil Unix seconds when the limit lifts
--- @field limit_type string|nil e.g. "five_hour"
--- @field retry_count number How many auto-resumes have already been spent on this limit hit
--- @field recorded_at number Unix seconds when the limit was first observed
--- @field state "waiting"|"in_flight" "waiting" until the continuation is actually sent. Only
---   "waiting" entries are re-armed on startup, so a session that died mid-request cannot have
---   its resume replayed for free by the next one.
--- @field kind "auto_resume"|"scheduled"|nil What to send when the timer fires. "auto_resume"
---   (the default when absent, so pre-existing stores keep working) sends the configured
---   continuation prompt; "scheduled" sends the chat's own unsent `## User` body.

--- Memoized `git rev-parse` results, keyed by the directory asked about.
--- A single fire()/on_rate_limited() call does several get/put/remove round trips, and each one
--- would otherwise spawn a synchronous subprocess on the main thread.
--- @type table<string, string|false>
local root_cache = {}

--- @param dir string|nil
--- @return string|nil
local function git_root_cached(dir)
  local key = dir or "<cwd>"
  local cached = root_cache[key]
  if cached ~= nil then
    return cached or nil
  end
  local root = Git.get_root(dir)
  root_cache[key] = root or false
  return root
end

--- Drop memoized roots (test helper; also useful after a worktree is added or removed)
function M.clear_cache()
  root_cache = {}
end

--- Resolve the store path for a working directory
--- @param cwd? string
--- @return string
function M.get_path(cwd)
  local root = git_root_cached(cwd) or cwd or vim.fn.getcwd()
  return root .. "/.vibing/pending-resume.json"
end

--- Resolve the store that owns a given chat file.
---
--- Per-chat reads and writes must anchor to the chat file itself, not to Neovim's current
--- directory: a `:cd` (or a chat whose `working_dir` is a worktree) between parking a resume and
--- firing it would otherwise resolve to a different project's store, and the pending entry would
--- silently vanish. Enumeration (`load`/`clear`) still uses the current project, since "which
--- chats am I resuming" is inherently scoped to the project Neovim was opened in.
--- @param chat_file_path string
--- @return string
function M.get_path_for_chat(chat_file_path)
  return M.get_path(vim.fn.fnamemodify(chat_file_path, ":h"))
end

--- Read the whole store
--- A missing or corrupt file yields an empty table: a resume that cannot be read is a resume that
--- silently does not happen, which is the safe direction for something that spends tokens.
--- @param cwd? string
--- @return table<string, Vibing.PendingResume>
function M.load(cwd)
  local path = M.get_path(cwd)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then
    return {}
  end

  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(decoded) ~= "table" then
    vim.notify("[vibing] Ignoring unreadable pending-resume.json", vim.log.levels.WARN)
    return {}
  end

  return decoded
end

--- Overwrite the whole store
--- @param entries table<string, Vibing.PendingResume>
--- @param cwd? string
--- @return boolean success
function M.save(entries, cwd)
  local path = M.get_path(cwd)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  -- vim.json.encode turns an empty Lua table into "[]" (an array), which decodes back as a list
  -- and would break every keyed lookup on the next load. Store an explicit empty object instead.
  local json = next(entries) == nil and "{}" or vim.json.encode(entries)

  local ok, err = pcall(vim.fn.writefile, { json }, path)
  if not ok then
    vim.notify("[vibing] Failed to write pending-resume.json: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

--- The directory a per-chat operation should resolve its store from.
--- Defaults to the chat file's own location rather than Neovim's cwd — see get_path_for_chat.
--- @param chat_file_path string
--- @param cwd string|nil Explicit override (tests, callers that already know the root)
--- @return string
local function chat_scope(chat_file_path, cwd)
  return cwd or vim.fn.fnamemodify(chat_file_path, ":h")
end

--- Record (or refresh) the pending resume for a chat
--- @param entry Vibing.PendingResume
--- @param cwd? string
function M.put(entry, cwd)
  local scope = chat_scope(entry.chat_file_path, cwd)
  local entries = M.load(scope)
  entries[entry.chat_file_path] = entry
  M.save(entries, scope)
end

--- Read one entry
--- @param chat_file_path string
--- @param cwd? string
--- @return Vibing.PendingResume|nil
function M.get(chat_file_path, cwd)
  return M.load(chat_scope(chat_file_path, cwd))[chat_file_path]
end

--- Drop one entry
--- @param chat_file_path string
--- @param cwd? string
function M.remove(chat_file_path, cwd)
  local scope = chat_scope(chat_file_path, cwd)
  local entries = M.load(scope)
  if entries[chat_file_path] == nil then
    return
  end
  entries[chat_file_path] = nil
  M.save(entries, scope)
end

--- Drop every entry
--- @param cwd? string
function M.clear(cwd)
  M.save({}, cwd)
end

return M
