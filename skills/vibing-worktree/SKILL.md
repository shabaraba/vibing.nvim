---
name: vibing-worktree
description: Create, list, attach to, and finish git-worktree-backed isolated work areas for vibing.nvim chats, entirely via natural language — no separate UI. Use when the user wants to isolate work in its own worktree ("split this into its own worktree", "start this in isolation"), wants to see what worktrees/branches exist ("what worktrees do I have", "what's in progress"), wants to switch/attach the current or a new chat to an existing worktree ("let's go into the auth-fix worktree", "attach to worktree X"), or wants to clean one up when done ("clean up this worktree", "I'm done with this branch's worktree").
---

# vibing-worktree

Git worktrees provide isolated working directories for parallel development. This skill uses
plain `git` commands and this chat's own frontmatter — no bespoke helper script, no metadata
file. A worktree's existence on disk is its entire state.

## Directory convention

Worktrees created for isolated work go under `.vibing/worktrees/<branch-name>/` at the git
root — flat, one worktree per directory, nothing else stored alongside it. This convention is
also stated in every vibing.nvim chat's system prompt; follow it so `git worktree list` stays
predictable for later listing.

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
out of curiosity or as a lead-in to attaching.

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

3. Find this chat's own file path. If the `vibing-nvim` MCP server is connected, call
   `mcp__vibing-nvim__nvim_get_info` to get it.
4. Edit that file's frontmatter, setting:

   ```yaml
   working_dir: .vibing/worktrees/<branch>
   ```

   (relative to the git root). Don't open a new chat buffer — the current conversation continues,
   and its next turn already runs in the new worktree.

5. If `nvim_get_info` isn't available (no `vibing-nvim` MCP connection), tell the user the
   worktree is ready at `.vibing/worktrees/<branch>` and that they'll need to set `working_dir`
   in the chat's frontmatter by hand (or open a new chat there) to actually start using it.

## Attach — "what worktrees are there? — let's go into the auth one"

Works the same whether this is a brand-new chat's first exchange or mid-conversation in an
existing one.

1. Run the **List** steps above to surface candidates.
2. Once the user picks one, follow **Create** steps 3-5 to point this chat's own `working_dir`
   frontmatter at the chosen worktree's path — the worktree already exists, so skip the
   `git worktree add` step.

## Finish — "clean up this worktree"

```bash
git worktree remove <path>
```

Never add `--force`. If git refuses because of uncommitted changes, that's it protecting the
user from losing work — report the exact error and let them decide whether to commit, stash, or
discard those changes themselves, rather than retrying with `--force` on their behalf.

If the removed path was this chat's own `working_dir`, clear that frontmatter field once removal
succeeds (reverting to the main repo root) — leaving it pointed at a now-deleted directory would
break the next turn.
