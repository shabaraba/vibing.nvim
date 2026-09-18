--- The request/response exchanges that are open right now.
---
--- A turn is the short-lived half of the pair `process_registry.lua` holds the other end of: it
--- starts when a prompt is sent and ends when that turn's `on_done` runs, whether or not the
--- process serving it survives (#774). Everything keyed here is per-turn — the callbacks the UI
--- answers on, the worktree the turn is writing in, the subagents it has in flight.
---
--- Requiring `process_registry` is allowed and one-way: `open` / `close` are the only writers of
--- `ProcessEntry.active_turn_id`, so the link between the two tables has exactly one author.
---
--- @module vibing.infrastructure.adapter.modules.turn_registry

local ProcessRegistry = require("vibing.infrastructure.adapter.modules.process_registry")

local M = {}

--- @class Vibing.TurnEntry
--- @field turn_id string The turn this entry is about, and the key of the table below.
--- @field process? Vibing.ProcessEntry The process serving it. Held as a reference rather than
---   copied field by field, so `adapter`, `chat_bufnr` and `session_id` have one home and cannot
---   drift: killing is done to a process, so it is named by one. Always set in production — the
---   adapter is the only caller of `open` — and optional only so that a spec exercising the turn
---   side alone need not invent one.
---
---   **This being non-nil is not "the process is alive."** A Lua reference outlives
---   `process_registry.unregister`, so a caller holding this table across the end of a turn keeps a
---   stale `ProcessEntry` whose `active_turn_id` has already been cleared. That is deliberate and
---   relied on — `permission.lua`'s `cancel_and_deny` cancels synchronously, which runs
---   `wrapped_on_done` and unregisters, and it still has to talk to the entry afterwards. Liveness
---   is a question for `process_registry.get(process_id)`, never for this field's nil-ness.
--- @field worktree_root? string Git worktree root this turn runs in, when it runs in one. The tree
---   is shared state, so a snapshot diff taken while another turn is mutating the same worktree
---   would attribute that turn's changes to this one — this is what lets the turn fall back to the
---   per-tool `request_diff` path instead (see core/utils/git_snapshot.lua).
--- @field on_insert_choices? fun(questions: table, waiting?: boolean)
---   `waiting` says the same thing it says on `on_approval_required`, for the same reason (#788):
---   this prompt is holding a turn that is still running, so the chat has to draw it now.
--- @field can_answer_question_in_place? boolean Whether `nvim_ask_user_question` may hold its MCP
---   reply open on this backend instead of killing the turn (#788). Resolved per turn from the
---   descriptor's measured floor against the configured budget, so the RPC handler never names a
---   backend.
--- @field on_approval_required? fun(tool: string, input: table, options: table, hook_request_id?: string, waiting?: boolean)
---   `waiting` says this prompt is holding a turn that is still running (#778), so the chat has to
---   draw it now — the kill path's drawing point, `_handle_response`, never comes.
--- @field subagent_count? number Task/Agent tool calls this turn has launched and not yet gotten a
---   tool_result for. Set to 0 by `M.open`; mutated only through `M.increment_subagent_count` /
---   `M.decrement_subagent_count`.

--- Keyed by turn id so concurrent chat buffers each resolve to their own turn instead of one
--- buffer's PreToolUse hook silently grabbing another buffer's callbacks.
--- @type table<string, Vibing.TurnEntry>
local turns = {}

--- Open a turn on an already-registered process.
--- @param entry Vibing.TurnEntry
function M.open(entry)
  entry.subagent_count = 0
  turns[entry.turn_id] = entry
  if entry.process then
    entry.process.active_turn_id = entry.turn_id
  end
end

--- Close a turn. The process it ran on stays registered; whether it also goes is the adapter's
--- call, not this module's.
--- @param turn_id string
function M.close(turn_id)
  local entry = turns[turn_id]
  if entry and entry.process and entry.process.active_turn_id == turn_id then
    entry.process.active_turn_id = nil
  end
  turns[turn_id] = nil
end

--- The turn with this id, or nil.
---
--- **No fallback of any kind.** An id that is present but matches nothing is a straggler from a
--- turn that has already closed, and lending it the sole live turn's answer is the #667 class of
--- defect; a caller that genuinely has no id asks `sole_open()` and says so. `git_snapshot`'s TTL
--- sweep is the reason this matters beyond tidiness: inheriting a sole-open fallback would report
--- every stale baseline as still open whenever one turn happened to be running, stopping the sweep
--- and leaving `refs/worktree/vibing/` to grow without bound.
--- @param turn_id string|nil
--- @return Vibing.TurnEntry|nil
function M.get(turn_id)
  if not turn_id then
    return nil
  end
  return turns[turn_id]
end

--- Whether a turn is still running, for the TTL sweeps that must not reap a live turn's state.
---
--- Lives here because the registry is the only place that knows: every adapter opens a turn when
--- its stream starts and closes it in `wrapped_on_done`. **Do not ask this of a process** — a
--- resident process (#774) is alive between turns too, so keying on "is the process there" stops
--- both sweeps forever. Both `git_snapshot.lua` and `request_diff.lua` need it, and having written
--- it twice is how the fallback path once shipped without it.
---
--- Defensive about `require` and about `get` raising, because a sweep that throws takes the tool
--- call it is running inside down with it; failing to "still open" would reap live state, so the
--- answer on failure is the conservative one.
--- @param turn_id string|nil
--- @return boolean
function M.is_open(turn_id)
  local ok, entry = pcall(M.get, turn_id)
  return ok and entry ~= nil
end

--- The sole turn currently open, or nil when there is none or more than one.
---
--- This is the only guess in the codebase about whose request an inbound call belongs to. Both
--- guessing callers — `rpc/hook_scope.lua` for a hook that named no process, and `get_by_chat_bufnr`
--- below for a bufnr that names none — reach it through here rather than open-coding it, so there is
--- one place to reason about and one place to delete once a resident process can name its own turn
--- on its own stdio (#774).
--- @return Vibing.TurnEntry|nil
function M.sole_open()
  local only_turn_id, only_entry = next(turns)
  if only_turn_id ~= nil and next(turns, only_turn_id) == nil then
    return only_entry
  end
  return nil
end

--- The turn a given process currently has open.
--- @param process_id string|nil
--- @return Vibing.TurnEntry|nil
function M.of_process(process_id)
  local process = ProcessRegistry.get(process_id)
  if process then
    return M.get(process.active_turn_id)
  end
  return nil
end

--- The turn open in a given chat buffer — the stable value embedded in the provider prompt (see the
--- backend command builders), used to route the backend-qualified nvim_ask_user_question MCP call
--- instead of a per-turn id (see the Vibing.ProcessEntry docstring, issues #469/#489).
---
--- A bufnr that names no process still falls back to the sole open turn: `--resume` replays earlier
--- turns, so the model can read a buffer number from a previous Neovim session and pass one that no
--- longer exists, and with a single turn open there is no other candidate. A bufnr that *does* name
--- a process with nothing open gets nil instead — that chat is idle, and answering with some other
--- chat's turn is a worse answer than none.
--- @param chat_bufnr number|nil
--- @return Vibing.TurnEntry|nil
function M.get_by_chat_bufnr(chat_bufnr)
  local process = ProcessRegistry.find_by_chat_bufnr(chat_bufnr)
  if process then
    return M.get(process.active_turn_id)
  end
  return M.sole_open()
end

--- Another turn writing in the same git worktree.
---
--- **Per turn, not per process.** Unlike `process_registry.find_other_holding_session` this is not
--- a conflict to refuse — the two chats are perfectly allowed to work in one tree. It only decides
--- which diff mechanism can honestly attribute the changes: a whole-tree snapshot cannot tell whose
--- `sed -i` ran, so a turn that overlaps another one in the same tree falls back to the per-tool
--- backups. Asked of processes instead, two resident processes in one repository would make every
--- chat overlap every other one forever, and the #625 snapshot mechanism would never be used again.
---
--- Excluded by turn id rather than by chat_bufnr: the backends that register no chat_bufnr at all
--- (currently grok and copilot — see features.md) would otherwise compare nil against nil and never
--- recognise each other as an overlap.
--- @param worktree_root string|nil
--- @param exclude_turn_id string|nil the turn asking; it is not an overlap with itself
--- @return Vibing.TurnEntry|nil
function M.find_other_writing_in(worktree_root, exclude_turn_id)
  if not worktree_root or worktree_root == "" then
    return nil
  end
  for turn_id, entry in pairs(turns) do
    if entry.worktree_root == worktree_root and turn_id ~= exclude_turn_id then
      return entry
    end
  end
  return nil
end

--- Record a Task/Agent tool_use starting in this turn's own transcript (never one nested inside a
--- subagent's transcript -- `cli_event_processor.lua` only reaches this for the parent's own tool
--- calls). Closing a turn drops the whole entry, so a subagent still in flight when its turn dies
--- is not leaked as a permanent count.
--- @param turn_id string|nil
function M.increment_subagent_count(turn_id)
  local entry = turns[turn_id]
  if entry then
    entry.subagent_count = entry.subagent_count + 1
  end
end

--- Record that Task/Agent tool call's result landing.
--- @param turn_id string|nil
function M.decrement_subagent_count(turn_id)
  local entry = turns[turn_id]
  if entry and entry.subagent_count > 0 then
    entry.subagent_count = entry.subagent_count - 1
  end
end

--- Subagents in flight across every open turn, for `application/chat/concurrency.lua`'s
--- `at_capacity()` -- five chats within their own limit can still be twenty processes deep if each
--- fans out four subagents (#701).
--- @return number
function M.total_subagent_count()
  local total = 0
  for _, entry in pairs(turns) do
    total = total + entry.subagent_count
  end
  return total
end

return M
