--- Registry for active stream callbacks
--- Allows RPC handlers (e.g., permission hook) to access chat buffer callbacks
--- @module vibing.infrastructure.adapter.modules.active_stream_registry

local M = {}

--- @class ActiveStreamEntry
--- @field handle_id string
--- @field chat_bufnr? number Stable value (the "Current vibing.nvim chat buffer number" line
---   embedded in the system prompt) used to route nvim_ask_user_question calls without a per-turn
---   handle_id, which would otherwise defeat Anthropic's prompt cache (see issues #469, #489).
--- @field session_id? string CLI session this stream is resuming. Two chat buffers can be bound to
---   the same session (a subagent chat shares its parent's), and two processes resuming one session
---   would write the same transcript concurrently — this is what lets a send be refused.
--- @field worktree_root? string Git worktree root this stream runs in, when it runs in one. The
---   tree is shared state, so a snapshot diff taken while another stream is mutating the same
---   worktree would attribute that stream's changes to this one — this is what lets the turn fall
---   back to the per-tool `request_diff` path instead (see core/utils/git_snapshot.lua).
--- @field adapter table ClaudeCLI adapter reference
--- @field on_insert_choices? fun(questions: table)
--- @field on_approval_required? fun(tool: string, input: table, options: table, hook_request_id?: string)

--- Keyed by handle_id so concurrent chat buffers each resolve to their own stream instead of
--- one buffer's PreToolUse hook silently grabbing another buffer's callbacks.
--- @type table<string, ActiveStreamEntry>
local streams = {}

--- Register an active stream's callbacks
--- @param entry ActiveStreamEntry
function M.register(entry)
  streams[entry.handle_id] = entry
end

--- Unregister a stream
--- @param handle_id string
function M.unregister(handle_id)
  streams[handle_id] = nil
end

--- Get an active stream entry by handle_id.
--- @param handle_id string|nil The requesting hook process's handle_id (passed via the
---   VIBING_HANDLE_ID env var). When nil (e.g. a hook process spawned before this env var
---   existed), falls back to the sole registered stream if exactly one is active — safe only
---   because there's no other candidate to confuse it with. With multiple concurrent streams
---   and no handle_id, returns nil rather than guessing which chat buffer triggered the hook.
--- @return ActiveStreamEntry|nil
function M.get(handle_id)
  if handle_id then
    return streams[handle_id]
  end

  local only_handle_id, only_entry = next(streams)
  if only_handle_id ~= nil and next(streams, only_handle_id) == nil then
    return only_entry
  end
  return nil
end

--- Get an active stream entry by chat buffer number — the stable value embedded in the system
--- prompt (see cli_command_builder.lua), used to route mcp__vibing-nvim__nvim_ask_user_question
--- calls instead of a per-turn handle_id (see the ActiveStreamEntry docstring, issues #469/#489).
--- Unlike M.get(), a non-matching bufnr still falls back to the sole registered stream: `--resume`
--- replays earlier turns, so the model can read a buffer number from a previous Neovim session and
--- pass one that no longer exists. With a single stream there is no other candidate to confuse it
--- with; with several, the loop above is what decides.
--- @param chat_bufnr number|nil
--- @return ActiveStreamEntry|nil
function M.get_by_chat_bufnr(chat_bufnr)
  if chat_bufnr then
    for _, entry in pairs(streams) do
      if entry.chat_bufnr == chat_bufnr then
        return entry
      end
    end
  end
  return M.get(nil)
end

--- Find another buffer's in-flight stream that is resuming the same session.
--- @param session_id string|nil
--- @param exclude_chat_bufnr number|nil the buffer asking; its own stream is not a conflict
--- @return ActiveStreamEntry|nil
function M.find_other_active_for_session(session_id, exclude_chat_bufnr)
  if not session_id or session_id == "" then
    return nil
  end
  for _, entry in pairs(streams) do
    if entry.session_id == session_id and entry.chat_bufnr ~= exclude_chat_bufnr then
      return entry
    end
  end
  return nil
end

--- Find another buffer's in-flight stream running in the same git worktree.
---
--- Unlike find_other_active_for_session this is not a conflict to refuse — the two chats are
--- perfectly allowed to work in one tree. It only decides which diff mechanism can honestly
--- attribute the changes: a whole-tree snapshot cannot tell whose `sed -i` ran, so a turn that
--- overlaps another one in the same tree falls back to the per-tool backups.
--- Excluded by handle_id rather than by chat_bufnr, unlike find_other_active_for_session: the
--- backends that register no chat_bufnr at all (codex, grok — see features.md) would otherwise
--- compare nil against nil and never recognise each other as an overlap.
--- @param worktree_root string|nil
--- @param exclude_handle_id string|nil the stream asking; it is not an overlap with itself
--- @return ActiveStreamEntry|nil
function M.find_other_active_for_worktree(worktree_root, exclude_handle_id)
  if not worktree_root or worktree_root == "" then
    return nil
  end
  for handle_id, entry in pairs(streams) do
    if entry.worktree_root == worktree_root and handle_id ~= exclude_handle_id then
      return entry
    end
  end
  return nil
end

return M
