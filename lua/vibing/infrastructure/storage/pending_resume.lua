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

--- Resolve the store path for a working directory
--- @param cwd? string
--- @return string
function M.get_path(cwd)
  local root = Git.get_root(cwd) or cwd or vim.fn.getcwd()
  return root .. "/.vibing/pending-resume.json"
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

--- Record (or refresh) the pending resume for a chat
--- @param entry Vibing.PendingResume
--- @param cwd? string
function M.put(entry, cwd)
  local entries = M.load(cwd)
  entries[entry.chat_file_path] = entry
  M.save(entries, cwd)
end

--- Read one entry
--- @param chat_file_path string
--- @param cwd? string
--- @return Vibing.PendingResume|nil
function M.get(chat_file_path, cwd)
  return M.load(cwd)[chat_file_path]
end

--- Drop one entry
--- @param chat_file_path string
--- @param cwd? string
function M.remove(chat_file_path, cwd)
  local entries = M.load(cwd)
  if entries[chat_file_path] == nil then
    return
  end
  entries[chat_file_path] = nil
  M.save(entries, cwd)
end

--- Drop every entry
--- @param cwd? string
function M.clear(cwd)
  M.save({}, cwd)
end

return M
