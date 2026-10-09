--- What a chat is for, as far as its fixed per-request cost is concerned (frontmatter `profile`).
---
--- Every request re-reads the whole system prompt, so a line that a chat never acts on is paid for
--- once per request for as long as the chat lives. `worker` is a chat driven by another chat rather
--- than read by a human as it runs: it drops the instructions that only make sense with someone
--- watching the editor. It keeps everything that changes what the work produces — the worktree
--- convention, the job rule, the question route, the report protocol and the project prompt —
--- because a worker that has to rediscover a rule costs more in re-reads than the line did.
---
--- Backend-neutral, like `effort`: a backend whose instruction block has nothing to drop for a
--- profile simply sends the same block. Switching profile is an ordinary frontmatter edit and takes
--- effect from the next request; it changes the system prompt, so it costs one prompt-cache miss.
--- @module vibing.core.constants.profiles
local M = {}

M.DEFAULT = "default"
M.WORKER = "worker"

--- @type string[]
M.VALUES = { M.DEFAULT, M.WORKER }

--- @param profile any
--- @return boolean
function M.is_valid(profile)
  return type(profile) == "string" and vim.tbl_contains(M.VALUES, profile)
end

--- The profile a request runs under. A missing value is the default; an unknown one warns and is
--- treated as the default, because the safe failure is the chat that sends *more* instructions.
--- @param profile any frontmatter `profile`
--- @return string
function M.resolve(profile)
  if profile == nil or profile == vim.NIL or profile == "" then
    return M.DEFAULT
  end
  if M.is_valid(profile) then
    return profile
  end
  require("vibing.core.utils.notify").warn(
    string.format("Ignoring unknown profile %s (valid: %s)", tostring(profile), table.concat(M.VALUES, ", ")),
    "Chat"
  )
  return M.DEFAULT
end

return M
