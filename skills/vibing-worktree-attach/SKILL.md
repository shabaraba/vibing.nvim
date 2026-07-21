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

2. Once the user picks one, find this chat's own file path. The system prompt contains a line
   like `Current vibing.nvim chat buffer file: /path/to/chat.md` — use that path directly. It is
   injected per-request by vibing.nvim and is always accurate even when multiple chat buffers are
   open. Avoid calling `mcp__vibing-nvim__nvim_get_info` for this purpose; it returns whichever
   buffer currently has focus in Neovim and may return the wrong one.
3. Edit that chat's frontmatter through the live Neovim buffer, not the file on disk — a brand-new
   chat (first exchange in a freshly opened buffer) has no file on disk yet, so `Read`/`Edit`
   against the path will simply fail or find nothing. Use the `vibing-nvim` MCP tools instead,
   which operate on buffer content regardless of save state:
   1. Call `nvim_list_buffers` and match `name` against the chat buffer path from the system
      prompt to get its `bufnr`. Don't assume `bufnr: 0` (current buffer) — the chat buffer may
      not have focus.
   2. Call `nvim_get_buffer({ bufnr })` to read the current content.
   3. Set `working_dir: <chosen worktree's path>` (relative to the git root) in the frontmatter
      block, then call `nvim_set_buffer({ bufnr, lines })` with the full updated content.

   Don't open a new chat buffer — the current conversation continues, and its next turn already
   runs in the chosen worktree.

4. If the `vibing-nvim` MCP connection isn't available at all, tell the user which worktree path
   to use and that they'll need to set `working_dir` in the chat's frontmatter by hand (or open a
   new chat there) to actually start using it.
