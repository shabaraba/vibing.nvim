---
name: vibing-workspace-done
description: Finish an active workspace — remove its git worktree — once the work in it is complete. Use when the user says things like "I'm done with workspace 0001", "wrap up the fix-auth-session workspace", "clean up this worktree, the PR is merged", or "mark this workspace finished".
---

# vibing-workspace-done

Removes a workspace's git worktree. Its `meta.yaml`/`plan.md` record stays on disk — only the
worktree (the actual checked-out files) goes away, which is what makes the workspace "done".

**Read `${CLAUDE_PLUGIN_ROOT}/skills/vibing-workspace/SKILL.md` first** for the directory layout
this skill operates on.

## Workflow

1. **Identify the workspace.** If the user named one, use it. Otherwise, if you know which
   workspace the current chat is associated with (check its `meta.yaml`'s `chat_files`, or ask),
   confirm that's the one they mean. If genuinely ambiguous, list active workspaces and ask —
   don't guess which one to finish.

2. **Check for reasons to double-check with the user before removing anything:**

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/vibing-workspace.mjs" check-done <workspace_id>
   ```

   This returns `{plan_incomplete, branch_merged}`. If `plan_incomplete` is true, the workspace's
   `plan.md` still has an unchecked `- [ ]` item — read the file and mention what's left, then ask
   if they still want to finish. If `branch_merged` is false, the branch doesn't appear to be
   merged into the current `HEAD` — mention this too (it might be intentionally unmerged, e.g.
   abandoned work, so don't refuse, just flag it). Neither condition should block you outright;
   they're both signals to surface to the user, not hard stops — the decision is theirs.

3. **Remove the worktree** (only after the user has confirmed, if step 2 raised anything):

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/vibing-workspace.mjs" remove-worktree <workspace_id>
   ```

   This runs `git worktree remove` **without `--force`**. If it fails because of uncommitted
   changes, that's git protecting the user from losing work — report the exact error and let them
   decide whether to commit, stash, or discard those changes themselves. Don't retry with force on
   their behalf; if they want that, they can say so explicitly and you can run
   `git worktree remove --force` directly (outside this skill's script, since the script won't do
   it either). Once this succeeds, the workspace is done — there's no separate step to mark it as
   such; `vibing-workspace-list`/`get` will already report it that way.

4. **Confirm completion** to the user, noting the workspace id and that its record (`meta.yaml`,
   `plan.md`) stays on disk for reference (its branch still exists in git too, just without a
   checked-out worktree).
