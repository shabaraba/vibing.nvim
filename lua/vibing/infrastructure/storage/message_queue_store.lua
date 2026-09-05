--- Persistence for chat-to-chat message queue entries that survive a Neovim restart
---
--- `message_queue.lua` keeps its live queue in memory, keyed by bufnr — a bufnr is only valid for
--- the Neovim process that created it. A destination chat can sit parked for hours on a
--- usage-limit reset (`pending_resume.lua` exists for exactly that gap, and its own doc notes a
--- restart is common across it), and a message queued for delivery to it would otherwise vanish
--- with nothing on disk to show it was ever there. State lives in
--- `<project root>/.vibing/message-queue.json` (gitignored like the rest of `.vibing/`), keyed by
--- the destination chat's file path, and is reloaded on startup by `message_queue.lua`'s
--- `M.restore()`.
---
--- @module vibing.infrastructure.storage.message_queue_store

local Git = require("vibing.core.utils.git")
local Fs = require("vibing.core.utils.fs")

local M = {}

--- @class Vibing.MessageQueueStore.Item
--- @field body string|nil Present for a message item; absent for a notification item
--- @field reason string|nil Notification items only (`ChatBuffer:get_stop_reason()`)
--- @field from_file_path string|nil Sender's chat file path. Absent when the sender had no
---   file (unnamed buffer) or, for a message item, when its sender was later forgotten.

--- Memoized `git rev-parse` results, keyed by the directory asked about. Mirrors
--- `pending_resume.lua`'s cache for the same reason: several round trips per call would otherwise
--- each spawn a synchronous subprocess on the main thread.
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
  return root .. "/.vibing/message-queue.json"
end

--- Resolve the store that owns a given chat file — same anchoring reason as
--- `pending_resume.get_path_for_chat`: a `:cd` between queueing and restore must not land on a
--- different project's store.
--- @param chat_file_path string
--- @return string
function M.get_path_for_chat(chat_file_path)
  return M.get_path(vim.fn.fnamemodify(chat_file_path, ":h"))
end

--- Read the whole store for a project.
--- A missing or corrupt file yields an empty table: entries that cannot be read are entries that
--- silently do not restore, which is the safe direction — the in-memory queue is still the
--- primary copy while Neovim is running.
--- @param cwd? string
--- @return table<string, Vibing.MessageQueueStore.Item[]>
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
    vim.notify("[vibing] Ignoring unreadable message-queue.json", vim.log.levels.WARN)
    return {}
  end

  return decoded
end

--- Overwrite the whole store
--- @param entries table<string, Vibing.MessageQueueStore.Item[]>
--- @param cwd? string
--- @return boolean success
function M.save(entries, cwd)
  local path = M.get_path(cwd)
  Fs.ensure_dir(vim.fn.fnamemodify(path, ":h"))

  -- vim.json.encode turns an empty Lua table into "[]" (an array), which decodes back as a list
  -- and would break every keyed lookup on the next load. Store an explicit empty object instead.
  local json = next(entries) == nil and "{}" or vim.json.encode(entries)

  local ok, err = pcall(vim.fn.writefile, { json }, path)
  if not ok then
    vim.notify("[vibing] Failed to write message-queue.json: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

--- Record (or clear) one destination's queue.
--- @param to_file_path string
--- @param items Vibing.MessageQueueStore.Item[]|nil nil or empty removes the entry
--- @param cwd? string
function M.put(to_file_path, items, cwd)
  local scope = cwd or vim.fn.fnamemodify(to_file_path, ":h")
  local entries = M.load(scope)
  if items and #items > 0 then
    entries[to_file_path] = items
  else
    if entries[to_file_path] == nil then
      return
    end
    entries[to_file_path] = nil
  end
  M.save(entries, scope)
end

return M
