--- The project's last observed usage-limit reset
---
--- `pending_resume.lua` answers "which chats are parked"; this answers the different question
--- "is the plan's limit currently exhausted", which a chat that has never hit the limit itself
--- still needs in order to schedule rather than send. One record per project, in
--- `<project root>/.vibing/limit-state.json`.
---
--- Only a record carrying a reset timestamp is stored: the StopFailure hook and the error-text
--- fallback confirm a rejection without saying when it lifts, and a record that cannot answer
--- "still active?" would strand every later request.
---
--- @module vibing.infrastructure.storage.limit_state

local Git = require("vibing.core.utils.git")

local M = {}

--- @class Vibing.LimitState
--- @field resets_at number Unix seconds when the limit lifts
--- @field limit_type string|nil e.g. "five_hour"
--- @field observed_at number Unix seconds when the limit was observed

--- Memoized `git rev-parse` results, keyed by the directory asked about — the same reason
--- pending_resume.lua caches: one send/receive cycle resolves the path several times.
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

--- @param cwd? string
--- @return string
function M.get_path(cwd)
  local root = git_root_cached(cwd) or cwd or vim.fn.getcwd()
  return root .. "/.vibing/limit-state.json"
end

--- Read the record, or nil when absent or unreadable.
--- @param cwd? string
--- @return Vibing.LimitState|nil
function M.load(cwd)
  local path = M.get_path(cwd)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then
    return nil
  end

  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(decoded) ~= "table" or type(decoded.resets_at) ~= "number" then
    return nil
  end

  return decoded
end

--- Record an observed limit. Ignored unless the payload carried a reset timestamp.
--- @param info Vibing.RateLimitInfo
--- @param cwd? string
--- @return boolean recorded
function M.record(info, cwd)
  if type(info) ~= "table" or type(info.resets_at) ~= "number" then
    return false
  end

  local path = M.get_path(cwd)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  local json = vim.json.encode({
    resets_at = info.resets_at,
    limit_type = info.limit_type,
    observed_at = os.time(),
  })

  local ok, err = pcall(vim.fn.writefile, { json }, path)
  if not ok then
    vim.notify("[vibing] Failed to write limit-state.json: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

--- The record, but only while the limit is still in force.
--- @param cwd? string
--- @return Vibing.LimitState|nil
function M.get_active(cwd)
  local state = M.load(cwd)
  if state and state.resets_at > os.time() then
    return state
  end
  return nil
end

--- Forget the recorded limit. Called on any successful response — a request that got through
--- proves the limit is not in force, whatever the stored reset time claimed.
--- @param cwd? string
function M.clear(cwd)
  local path = M.get_path(cwd)
  if vim.fn.filereadable(path) == 1 then
    pcall(vim.fn.delete, path)
  end
end

return M
