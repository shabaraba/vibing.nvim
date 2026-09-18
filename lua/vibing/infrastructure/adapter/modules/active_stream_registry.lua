--- Registry for active stream callbacks
--- Allows RPC handlers (e.g., permission hook) to access chat buffer callbacks
--- @module vibing.infrastructure.adapter.modules.active_stream_registry

local M = {}

--- @class ActiveStreamEntry
--- @field handle_id string The turn this entry is about, and the key of the table below.
--- @field process_id string The CLI process serving that turn — the value of the child's
---   `VIBING_PROCESS_ID`, the key of `adapter._processes`, and the only thing `adapter:cancel()`
---   accepts. Under the oneshot transport a process serves exactly one turn, so a live entry is
---   also the whole truth about a live process; that is a property of the transport rather than an
---   invariant anything here may rely on (#774).
--- @field chat_bufnr? number Stable value (the "Current vibing.nvim chat buffer number" line
---   embedded in the model-visible provider prompt) used to route nvim_ask_user_question calls
---   without a per-turn handle_id, which would otherwise defeat provider prompt caching (see
---   issues #469, #489).
--- @field session_id? string CLI session this stream is resuming. Two chat buffers can be bound to
---   the same session (a subagent chat shares its parent's), and two processes resuming one session
---   would write the same transcript concurrently — this is what lets a send be refused.
--- @field worktree_root? string Git worktree root this stream runs in, when it runs in one. The
---   tree is shared state, so a snapshot diff taken while another stream is mutating the same
---   worktree would attribute that stream's changes to this one — this is what lets the turn fall
---   back to the per-tool `request_diff` path instead (see core/utils/git_snapshot.lua).
--- @field adapter table backend adapter reference
--- @field on_insert_choices? fun(questions: table)
--- @field on_approval_required? fun(tool: string, input: table, options: table, hook_request_id?: string)
--- @field subagent_count? number Task/Agent tool calls this stream has launched and not yet gotten
---   a tool_result for. Set to 0 by `M.register`; mutated only through `M.increment_subagent_count`
---   / `M.decrement_subagent_count`.

--- Keyed by handle_id so concurrent chat buffers each resolve to their own stream instead of
--- one buffer's PreToolUse hook silently grabbing another buffer's callbacks.
--- @type table<string, ActiveStreamEntry>
local streams = {}

--- The first entry the predicate accepts, or nil. Every lookup below a key lookup is a scan of this
--- table, and they are written once here so the four of them cannot drift apart.
--- @param predicate fun(entry: ActiveStreamEntry, turn_id: string): boolean
--- @return ActiveStreamEntry|nil
local function find(predicate)
  for turn_id, entry in pairs(streams) do
    if predicate(entry, turn_id) then
      return entry
    end
  end
  return nil
end

--- Register an active stream's callbacks
--- @param entry ActiveStreamEntry
function M.register(entry)
  entry.subagent_count = entry.subagent_count or 0
  streams[entry.handle_id] = entry
end

--- Unregister a stream
--- @param handle_id string
function M.unregister(handle_id)
  streams[handle_id] = nil
end

--- Record a Task/Agent tool_use starting in this stream's own transcript (never one nested inside
--- a subagent's transcript -- `cli_event_processor.lua` only reaches this for the parent's own
--- tool calls). A stream ending unregisters the whole entry, so a subagent still in flight when
--- its turn dies is not leaked as a permanent count.
--- @param handle_id string|nil
function M.increment_subagent_count(handle_id)
  local entry = streams[handle_id]
  if entry then
    entry.subagent_count = entry.subagent_count + 1
  end
end

--- Record that Task/Agent tool call's result landing.
--- @param handle_id string|nil
function M.decrement_subagent_count(handle_id)
  local entry = streams[handle_id]
  if entry and entry.subagent_count > 0 then
    entry.subagent_count = entry.subagent_count - 1
  end
end

--- Subagents in flight across every active stream, for `application/chat/concurrency.lua`'s
--- `at_capacity()` -- five chats within their own limit can still be twenty processes deep if each
--- fans out four subagents (#701).
--- @return number
function M.total_subagent_count()
  local total = 0
  for _, entry in pairs(streams) do
    total = total + entry.subagent_count
  end
  return total
end

--- The sole stream currently in flight, or nil when there is none or more than one.
---
--- This is the only guess in the codebase about whose request an inbound hook belongs to, and it is
--- named rather than open-coded so that there is one place to reason about — and one place to
--- delete once a resident process can name its own turn on its own stdio (#774).
---
--- It is honest today because a registered stream *is* a running turn: an entry exists from
--- `stream()` to `wrapped_on_done`, so "exactly one entry" really does mean "there is no other
--- candidate to confuse it with".
--- @return ActiveStreamEntry|nil
function M.sole_active()
  local only_handle_id, only_entry = next(streams)
  if only_handle_id ~= nil and next(streams, only_handle_id) == nil then
    return only_entry
  end
  return nil
end

--- Get an active stream entry by the turn it is about.
---
--- Strict, like `find_by_process_id` and for the same reason: a fallback baked into an accessor is
--- what let `get_active_opts` answer a late hook with another chat's decisions. A caller that wants
--- the guess asks `sole_active()` by name — `get_by_chat_bufnr` is the one that does.
--- @param handle_id string|nil
--- @return ActiveStreamEntry|nil
function M.get(handle_id)
  return handle_id and streams[handle_id] or nil
end

--- Get an active stream entry by the process serving it.
---
--- The inbound path for both shell hooks: `VIBING_PROCESS_ID` is fixed at spawn, so a process is
--- the only thing a hook can name, and the turn is resolved here rather than travelling on the
--- wire. **Deliberately strict** — an unmatched id returns nil instead of falling back to
--- `sole_active()`. The caller decides whether to guess, because the two callers want different
--- answers: an approval prompt shown in the wrong buffer is recoverable, and a diff baseline opened
--- under the wrong turn silently mis-attributes another chat's edits.
--- @param process_id string|nil
--- @return ActiveStreamEntry|nil
function M.find_by_process_id(process_id)
  if not process_id then
    return nil
  end
  return find(function(entry)
    return entry.process_id == process_id
  end)
end

--- Get an active stream entry by chat buffer number — the stable value embedded in the provider
--- prompt (see the backend command builders), used to route the backend-qualified
--- nvim_ask_user_question MCP call instead of a per-turn handle_id (see the ActiveStreamEntry
--- docstring, issues #469/#489).
--- Unlike M.get(), a non-matching bufnr still falls back to the sole registered stream: `--resume`
--- replays earlier turns, so the model can read a buffer number from a previous Neovim session and
--- pass one that no longer exists. With a single stream there is no other candidate to confuse it
--- with; with several, the loop above is what decides.
--- @param chat_bufnr number|nil
--- @return ActiveStreamEntry|nil
function M.get_by_chat_bufnr(chat_bufnr)
  local entry = chat_bufnr
    and find(function(candidate)
      return candidate.chat_bufnr == chat_bufnr
    end)
  return entry or M.sole_active()
end

--- Find another buffer's in-flight stream that is resuming the same session.
--- @param session_id string|nil
--- @param exclude_chat_bufnr number|nil the buffer asking; its own stream is not a conflict
--- @return ActiveStreamEntry|nil
function M.find_other_active_for_session(session_id, exclude_chat_bufnr)
  if not session_id or session_id == "" then
    return nil
  end
  return find(function(entry)
    return entry.session_id == session_id and entry.chat_bufnr ~= exclude_chat_bufnr
  end)
end

--- Find another buffer's in-flight stream running in the same git worktree.
---
--- Unlike find_other_active_for_session this is not a conflict to refuse — the two chats are
--- perfectly allowed to work in one tree. It only decides which diff mechanism can honestly
--- attribute the changes: a whole-tree snapshot cannot tell whose `sed -i` ran, so a turn that
--- overlaps another one in the same tree falls back to the per-tool backups.
--- Excluded by handle_id rather than by chat_bufnr, unlike find_other_active_for_session: the
--- backends that register no chat_bufnr at all (currently grok and copilot — see features.md)
--- would otherwise compare nil against nil and never recognise each other as an overlap.
--- @param worktree_root string|nil
--- @param exclude_handle_id string|nil the stream asking; it is not an overlap with itself
--- @return ActiveStreamEntry|nil
function M.find_other_active_for_worktree(worktree_root, exclude_handle_id)
  if not worktree_root or worktree_root == "" then
    return nil
  end
  return find(function(entry, turn_id)
    return entry.worktree_root == worktree_root and turn_id ~= exclude_handle_id
  end)
end

return M
