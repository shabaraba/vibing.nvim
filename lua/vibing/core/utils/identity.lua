--- The two identities a CLI request has, and the one character class both must survive.
---
--- A **process id** names an OS process running a CLI. A **turn id** names one request/response
--- exchange on such a process. Today a process serves exactly one turn, so the two are always
--- minted together and discarded together — but they are two values rather than one value with two
--- meanings, because a resident process (#774) serves many turns in sequence and every consumer
--- has to have already said which of the two it meant.
---
--- **Nothing may parse an id to learn its kind.** Both minters emit the same shape deliberately:
--- a consumer that guessed from the text would be reading a convention no invariant protects.
---
--- Three consumers sanitize an id, and `HOOK_SAFE_CLASS` is the **strictest** of the three, which is
--- why declaring it here is enough: an id that survives it survives the other two.
---   - `bin/hooks/pre-tool-use.sh` / `bin/hooks/stop-failure.sh` delete exactly this class from
---     `VIBING_PROCESS_ID` before interpolating it into their JSON request. A dropped character
---     makes the hook name a process that is not in the registry, and the turn resolves to nil.
---   - `git_snapshot.sanitize` keeps `-` as well, for `refs/worktree/vibing/<turn_id>`.
---   - `send_message`'s `.vibing/patches/*.patch` suffix keeps alphanumerics only.
--- Those two keep their own expressions, because they are their own constraints rather than copies
--- of this one — but neither can reject what is minted here.
---
--- The shell is the half nothing could check: `test:lua` never runs it, so a rename there would
--- break hook attribution with every unit test still green. `identity_spec.lua` therefore reads the
--- class and the params key back out of both scripts and compares them to this module.
---
--- Hex, not decimal: LuaJIT's `tostring()` renders large `hrtime` doubles in scientific notation
--- ("2.64e+15"), whose `.` and `+` are both in the deleted class — so two ids minted in the same
--- millisecond could collapse onto one sanitized value.
--- @module vibing.core.utils.identity

local M = {}

--- The character class both shell hooks delete from the id they are handed. Written exactly as the
--- scripts write it, so the spec can compare the two literally rather than by behaviour.
M.HOOK_SAFE_CLASS = "[^A-Za-z0-9_]"

--- Seeded once per Neovim session rather than per mint: `math.randomseed` is process-global, and
--- re-seeding from `hrtime` on every call makes the sequence a function of the clock instead of
--- adding entropy to it.
local seeded = false

--- @return string
local function mint()
  if not seeded then
    math.randomseed(vim.loop.hrtime())
    seeded = true
  end
  return string.format("%016x_%x", vim.loop.hrtime(), math.random(100000))
end

--- @return string
function M.new_process_id()
  return mint()
end

--- @return string
function M.new_turn_id()
  return mint()
end

return M
