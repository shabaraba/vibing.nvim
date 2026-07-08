---
name: vibing-workspace-create
description: Create a new git-worktree-backed workspace (worktree + meta.yaml + plan.md) for a piece of work, instead of running `git worktree add` by hand. Use whenever the user wants to start work on a feature/fix/task in isolation — phrases like "start a new workspace for X", "create a worktree for this", "let's work on X in its own branch", or "spin up an isolated environment for Y" — even if they don't say "workspace" explicitly and just describe a task they want to isolate from their current branch.
---

# vibing-workspace-create

Creates a new workspace: a numbered `.vibing/workspace/<id>/` directory containing a git
worktree, a `meta.yaml` recording what it's for, and a `plan.md` scratchpad — instead of a bare
`git worktree add` that leaves no record of intent or progress.

**Read `${CLAUDE_PLUGIN_ROOT}/skills/vibing-workspace/SKILL.md` first** — it explains the
directory layout, `meta.yaml` schema, and the `scripts/vibing-workspace.mjs` helper this skill
calls. Don't duplicate that reasoning here; this file only covers what's specific to _creating_ a
workspace.

## Workflow

1. **Understand the task.** If the user's request doesn't already make clear what the work is
   (a one-line description is enough — "fix the auth session bug", "add dark mode"), ask. Don't
   guess at something this consequential — the description becomes the workspace's label and the
   first line of its `plan.md`.

2. **Propose a branch name yourself.** Turn the task description into an English, lowercase,
   kebab-case branch name (e.g. "認証セッションのバグを直したい" → `fix-auth-session-bug`,
   "add dark mode toggle" → `add-dark-mode-toggle`). Keep it short — under ~40 characters. Show
   both the description (as you understood it) and the branch name you propose, and let the user
   correct either before continuing. This is a cheap step and a wrong branch name is annoying to
   undo later, so don't skip the confirmation even if you're confident.

3. **Create it.**

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/vibing-workspace.mjs" create <branch> "<description>"
   ```

   This prints `{id, dir, worktree_path, meta_path, plan_path}` on success. If it fails (invalid
   branch name, git worktree error), the error on stderr is usually self-explanatory — surface it
   to the user rather than retrying blindly with a different branch name on their behalf.

4. **Record the current chat, if there is one.** If the `vibing-nvim` MCP server is connected,
   look up the current chat file via `mcp__vibing-nvim__nvim_get_info` and register it:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/vibing-workspace.mjs" add-chat-file <id> <chat_file_path>
   ```

   Use a path relative to the git root if the chat file lives inside the repo (e.g.
   `.vibing/chat/2026-07-03-abc.md`), otherwise the absolute path. If there's no `vibing-nvim`
   connection (plain terminal use), skip this step — the workspace is still fully created.

5. **Tell the user what happened**, including the workspace id (they'll use it to refer back to
   this workspace later) and the worktree path. If they want to start working right away, `cd`
   into `<worktree_path>` (or open it in their editor) — this skill only creates the workspace,
   it doesn't switch you into it.

## Things worth knowing

- The branch is created fresh (`git worktree add -b <branch>`) unless a branch with that exact
  name already exists locally, in which case the existing branch is checked out into the new
  worktree — useful for resuming work whose branch survived a previous workspace being marked
  done.
- Common config files (`.gitignore`, `package.json`, `tsconfig.json`, lockfiles, etc.) are copied
  into the new worktree automatically, and `node_modules` is symlinked from the main repo if it
  exists there — this mirrors what a fresh `git worktree add` would leave you to set up by hand.
- If workspace creation fails partway through (e.g. the git worktree step fails), the script
  cleans up the partially-created workspace directory itself — you don't need to manually delete
  anything.
