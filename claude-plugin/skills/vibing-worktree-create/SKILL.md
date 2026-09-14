---
name: vibing-worktree-create
description: Create a new git-worktree-backed isolated work area for the current vibing.nvim chat via natural language — no separate UI. Use when the user wants to isolate work in its own worktree ("split this into its own worktree", "start this in isolation", "give this its own branch").
---

# vibing-worktree-create

Git worktrees provide isolated working directories for parallel development. This skill uses
plain `git` commands and this chat's own frontmatter — no bespoke helper script, no metadata
file. A worktree's existence on disk is its entire state.

## Directory convention

Worktrees created for isolated work go under `.vibing/worktrees/<branch-name>/` at the git
root — flat, one worktree per directory, nothing else stored alongside it. This convention is
also stated in every vibing.nvim chat's system prompt; follow it so `git worktree list` stays
predictable for later listing (see the `vibing-worktree-list` skill).

## Create — "split this off into its own worktree"

1. Derive a short, English, lowercase, kebab-case branch name from the task being discussed
   (e.g. "認証セッションのバグを直したい" → `fix-auth-session-bug`). Confirm it with the user if
   the mapping isn't obvious — a wrong name is annoying to rename later.
2. Create the worktree:

   ```bash
   git worktree add -b <branch> .vibing/worktrees/<branch>
   ```

   If this fails (branch already checked out elsewhere, etc.), the error is self-explanatory —
   surface it verbatim rather than retrying blindly with a different name.

3. **Do not edit the frontmatter.** vibing.nvim writes `working_dir` itself at the end of this
   turn, by comparing `git worktree list` from before the command ran against after it. Setting
   it by hand races that and can leave the field pointing at a worktree the command failed to
   create. Just tell the user the worktree is ready.

   Don't open a new chat buffer either — the current conversation continues, and its next turn
   already runs in the new worktree.

If the field is still empty on the next turn, the `git worktree add` did not actually create
anything; read its error rather than writing `working_dir` to paper over it. A chat whose
`working_dir` is empty reports **no changes at all** for work done inside a worktree, so an
incorrect value is worse than none.
