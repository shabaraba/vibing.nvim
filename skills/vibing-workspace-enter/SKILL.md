---
name: vibing-workspace-enter
description: Register the current chat/conversation against an existing active workspace, so a second conversation can pick up work in the same worktree that another chat already started. Use when the user wants to continue or join work already in progress under a workspace — phrases like "enter workspace 0001", "let's continue the fix-auth-session workspace here", "switch this chat to the dark-mode workspace", or "which workspaces are active" as a lead-in to picking one.
---

# vibing-workspace-enter

Binds the current conversation to an already-existing active workspace by adding this chat file
to its `meta.yaml`. This does not create anything or exclude other chats — any number of chats
can be associated with the same workspace over time.

**Read `${CLAUDE_PLUGIN_ROOT}/skills/vibing-workspace/SKILL.md` first** for the directory layout
and `meta.yaml` schema this skill relies on.

## Workflow

1. **Identify the target workspace.** If the user named one (an id like `0001-fix-auth-session-bug`,
   or a description close enough to match), use it. Otherwise list active workspaces and ask:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/vibing-workspace.mjs" list active
   ```

   Present the `id` and `description` of each so the user can pick — don't guess when there's more
   than one plausible match.

2. **Confirm it's really active.**

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/vibing-workspace.mjs" get <workspace_id>
   ```

   If this fails or reports `"status": "done"`, tell the user — a done workspace's worktree no
   longer exists, so there's nothing to enter (they may want `vibing-workspace-create` to start
   fresh work on the same topic instead).

3. **Record this chat.** If the `vibing-nvim` MCP server is connected, get the current chat file
   via `mcp__vibing-nvim__nvim_get_info` and register it:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/vibing-workspace.mjs" add-chat-file <workspace_id> <chat_file_path>
   ```

   If there's no `vibing-nvim` connection, there's no chat file to record — just proceed to the
   next step; entering still means something (you now know which worktree to work in).

4. **Tell the user the worktree path** (from the `get` output) so they know where to actually do
   the work — this skill registers the association, it doesn't `cd` anywhere or open any files by
   itself.

## Things worth knowing

- There's no exclusivity constraint: a chat that's already associated with one workspace can be
  registered against a different one too if the user genuinely wants that (though normally a
  fresh conversation per workspace keeps things clearer). This skill doesn't refuse based on prior
  associations — use judgment about whether that's actually what the user wants.
- `add-chat-file` is idempotent — entering a workspace you're already registered against is a
  harmless no-op, not an error.
