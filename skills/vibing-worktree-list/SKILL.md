---
name: vibing-worktree-list
description: List git-worktree-backed isolated work areas for vibing.nvim chats via natural language — no separate UI. Use when the user wants to see what worktrees/branches exist ("what worktrees do I have", "what's in progress", "show me all worktrees").
---

# vibing-worktree-list

Git worktrees provide isolated working directories for parallel development. This skill uses
plain `git` commands — no bespoke helper script, no metadata file. A worktree's existence on disk
is its entire state.

## Directory convention

Worktrees created for isolated work go under `.vibing/worktrees/<branch-name>/` at the git
root — flat, one worktree per directory, nothing else stored alongside it. This convention is
also stated in every vibing.nvim chat's system prompt.

## List — "what worktrees exist?"

```bash
git worktree list --porcelain
```

For a one-line hint of what was last done on a given worktree's branch:

```bash
git log -1 --format=%s <branch>
```

This shows every worktree registered against the repo, not just ones under
`.vibing/worktrees/` — including ones created outside vibing.nvim entirely (a bare
`git worktree add`, or `claude --worktree` run directly in a terminal). Present branch, path,
and (if you fetched it) the last commit message so the user can pick one, whether they're asking
out of curiosity or as a lead-in to attaching (see the `vibing-worktree-attach` skill).
