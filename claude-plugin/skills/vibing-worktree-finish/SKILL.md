---
name: vibing-worktree-finish
description: Remove a git-worktree-backed isolated work area for vibing.nvim chats via natural language — no separate UI. Use when the user wants to clean one up when done ("clean up this worktree", "I'm done with this branch's worktree", "remove the auth-fix worktree").
---

# vibing-worktree-finish

Git worktrees provide isolated working directories for parallel development. This skill removes
one via plain `git worktree remove` — no bespoke helper script, no metadata file to update beyond
this chat's own frontmatter.

## Finish — "clean up this worktree"

```bash
git worktree remove <path>
```

Never add `--force`. If git refuses because of uncommitted changes, that's it protecting the
user from losing work — report the exact error and let them decide whether to commit, stash, or
discard those changes themselves, rather than retrying with `--force` on their behalf.

If the removed path was this chat's own `working_dir`, clear that frontmatter field once removal
succeeds (reverting to the main repo root) — leaving it pointed at a now-deleted directory would
break the next turn. Follow the `vibing-nvim` MCP buffer-editing approach described in steps 3-4
of the `vibing-worktree-create` skill to edit the live buffer rather than the file on disk.
