---
name: vibing-worktree-attach
description: Attach the current or a new vibing.nvim chat to an already-existing git worktree via natural language — no separate UI. Use when the user wants to switch/attach a chat to an existing worktree ("let's go into the auth-fix worktree", "attach to worktree X", "continue in the feature-y worktree").
---

# vibing-worktree-attach

Git worktrees provide isolated working directories for parallel development. This skill points
this chat's own `working_dir` frontmatter at an already-existing worktree — it never creates one
(see the `vibing-worktree-create` skill for that) and never runs `git worktree add`.

## Attach — "what worktrees are there? — let's go into the auth one"

Works the same whether this is a brand-new chat's first exchange or mid-conversation in an
existing one.

1. Surface candidates (see the `vibing-worktree-list` skill):

   ```bash
   git worktree list --porcelain
   ```

2. Once the user picks one, follow steps 3-5 of the `vibing-worktree-create` skill to point this
   chat's own `working_dir` frontmatter at the chosen worktree's path via the `vibing-nvim` MCP
   tools — the worktree already exists, so there's no `git worktree add` step to run first, and
   there's no new chat buffer to open (the current conversation continues, and its next turn
   already runs in the chosen worktree).
