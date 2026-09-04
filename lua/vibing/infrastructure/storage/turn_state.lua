--- What each chat's previous turn looked like
---
--- `prefix_rewrite.lua` can only name a cause by comparing this turn against the last one, and
--- three of the five facts it needs -- the model, the Claude Code version, and whether the turn
--- compacted -- exist nowhere else once the CLI process has exited. Frontmatter holds the
--- *current* model, not the one the previous turn actually ran with.
---
--- It is measurement metadata rather than conversation, which is why it lives here and not in
--- the chat file: nothing a user would want to read or edit, and a chat file that grew five keys
--- of bookkeeping would be paying for this feature on every line of every diff.
---
--- One file per project, `<git root>/.vibing/turn-state.json`, keyed by chat file path. A key
--- that goes stale (the chat renamed, the store deleted) costs exactly one turn of "no likely
--- cause found" -- the same degrade-don't-break bargain the rest of this path makes.
---
--- The read-modify-write is not atomic, so two chats finishing in the same instant can drop one
--- of the two records. That is left alone deliberately: the cost is one turn of "no likely cause
--- found" for one chat, which is the same failure the paragraph above already accepts, and it is
--- not worth a lock file on a path that runs at the end of every turn. `limit_state.lua` makes
--- the same trade.
---
--- @module vibing.infrastructure.storage.turn_state

local Fs = require("vibing.core.utils.fs")
local Git = require("vibing.core.utils.git")

local M = {}

--- Forget entries this old on the next write. A chat untouched for a month has nothing useful
--- to say about a cache TTL measured in hours, and this is what bounds the file.
local MAX_AGE_SECONDS = 30 * 24 * 60 * 60

--- Memoized `git rev-parse` results, keyed by the directory asked about -- the same reason
--- `limit_state.lua` caches: one send/receive cycle resolves the path more than once.
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

--- The physical path of a chat file, which is what both the key and the store location are keyed
--- on.
---
--- `nvim_buf_get_name` hands back a path the editor has already resolved, while a caller holding
--- the string it opened the chat with has not. On macOS that difference is `/var/...` against
--- `/private/var/...` for the same file -- two keys, two store files, and a record that can never
--- be read back by the other side. `fnamemodify(":p")` does not collapse a symlink; only
--- `resolve()` does.
--- @param chat_path string
--- @return string
local function physical(chat_path)
  return vim.fn.resolve(vim.fn.fnamemodify(chat_path, ":p"))
end

--- The store that holds `chat_path`'s record.
---
--- Derived from the chat file rather than from the request's working directory, because the chat
--- file is what the record is *about*. A chat whose `working_dir` points at a worktree would
--- otherwise leave its history behind the moment that worktree is removed.
--- @param chat_path string
--- @return string
function M.get_path(chat_path)
  local dir = vim.fn.fnamemodify(physical(chat_path), ":h")
  local root = git_root_cached(dir) or dir
  return root .. "/.vibing/turn-state.json"
end

--- @param path string store path from `M.get_path`
--- @return table<string, Vibing.TurnFacts>
local function read_all(path)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" or #lines == 0 then
    return {}
  end

  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

--- Read a chat's previous turn, or nil when there is none on record.
--- @param chat_path string|nil
--- @return Vibing.TurnFacts|nil
function M.load(chat_path)
  if type(chat_path) ~= "string" or chat_path == "" then
    return nil
  end

  local entry = read_all(M.get_path(chat_path))[physical(chat_path)]
  if type(entry) ~= "table" or type(entry.at) ~= "number" then
    return nil
  end
  return entry
end

--- Record this turn as the one the next turn compares against.
--- @param chat_path string|nil
--- @param facts Vibing.TurnFacts
--- @return boolean recorded
function M.record(chat_path, facts)
  if type(chat_path) ~= "string" or chat_path == "" or type(facts) ~= "table" then
    return false
  end

  local path = M.get_path(chat_path)
  local all = read_all(path)

  -- Swept before the new entry goes in, not after. Sweeping afterwards makes the retention rule
  -- apply to the record being written, so a turn whose `at` is older than the window -- a clock
  -- that jumped, a fixture -- is dropped by the same call that stored it, and reads back nil.
  local cutoff = os.time() - MAX_AGE_SECONDS
  for key, entry in pairs(all) do
    if type(entry) ~= "table" or type(entry.at) ~= "number" or entry.at < cutoff then
      all[key] = nil
    end
  end
  all[physical(chat_path)] = facts

  Fs.ensure_dir(vim.fn.fnamemodify(path, ":h"))

  local ok, encoded = pcall(vim.json.encode, all)
  if not ok then
    return false
  end

  local written = pcall(vim.fn.writefile, { encoded }, path)
  if not written then
    -- Silent: the only thing lost is the *next* turn's cause diagnosis, and a notification for
    -- that on every turn would cost the user more than the feature is worth.
    return false
  end
  return true
end

return M
