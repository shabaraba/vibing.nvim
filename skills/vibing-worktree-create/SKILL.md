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

3. Find this chat's own file path. The system prompt contains a line like
   `Current vibing.nvim chat buffer file: /path/to/chat.md` — use that path directly. It is
   injected per-request by vibing.nvim and is always accurate even when multiple chat buffers
   are open. Avoid calling `mcp__vibing-nvim__nvim_get_info` for this purpose; it returns
   whichever buffer currently has focus in Neovim and may return the wrong one.
4. Edit that chat's frontmatter through the live Neovim buffer, not the file on disk — a brand-new
   chat (first exchange in a freshly opened buffer) has no file on disk yet, so `Read`/`Edit`
   against the path will simply fail or find nothing. Use the `vibing-nvim` MCP tools instead,
   which operate on buffer content regardless of save state:
   1. Call `nvim_list_buffers` and match `name` against the chat buffer path from the system
      prompt to get its `bufnr`. Don't assume `bufnr: 0` (current buffer) — the chat buffer may
      not have focus.
   2. Call `nvim_get_buffer({ bufnr })` to read the current content.
   3. Set `working_dir: .vibing/worktrees/<branch>` (relative to the git root) in the frontmatter
      block, then call `nvim_set_buffer({ bufnr, lines })` with the full updated content.

   Don't open a new chat buffer — the current conversation continues, and its next turn already
   runs in the new worktree.

5. If the `vibing-nvim` MCP connection isn't available at all, tell the user the worktree is
   ready at `.vibing/worktrees/<branch>` and that they'll need to set `working_dir` in the chat's
   frontmatter by hand (or open a new chat there) to actually start using it.
