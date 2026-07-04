---
name: vibing-workspace-list
description: List active or done git-worktree-backed workspaces in the current project, so the user can see what's in progress or check on past work. Use for requests like "what workspaces do I have going", "show me active workspaces", "what's still in progress", or "list finished workspaces".
---

# vibing-workspace-list

Lists workspaces recorded under `.vibing/workspace/active/` or `.vibing/workspace/done/`.

**Read `${CLAUDE_PLUGIN_ROOT}/skills/vibing-workspace/SKILL.md` first** for what a workspace is
and how `meta.yaml` is structured.

## Workflow

1. Run the listing:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/vibing-workspace.mjs" list active
   ```

   Use `list done` instead if the user asked for finished/done workspaces specifically. If they
   didn't specify, default to `active` — that's almost always what "what am I working on" means.

2. Present each entry's `id`, `description`, and `branch` in a short, scannable list — the id is
   what the user needs to refer back to a workspace in `vibing-workspace-enter` or
   `vibing-workspace-done`, so make sure it's visible, not just the description.

3. If the list is empty, say so plainly rather than treating it as an error — an empty active
   list often just means nothing is in progress right now.

4. If the user's request is ambiguous about active vs. done (e.g. "show me all my workspaces"),
   it's fine to run both and present them in two labeled sections rather than guessing which one
   they meant.
