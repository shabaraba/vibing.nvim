# E2E Test Scenarios: Worktree Integration (`vibing-worktree-*` skills)

These scenarios exercise the `vibing-worktree-{list,create,attach,finish}` skills' four
natural-language flows against a real chat session. Each scenario assumes a fresh chat in a git
repository with at least one commit, and that the `vibing-nvim` MCP server is connected unless a
scenario says otherwise.

## 1. List worktrees

**Steps:**

1. In a chat, send: "what worktrees exist in this repo right now?"
2. Observe Claude run `git worktree list --porcelain` (and optionally `git log -1 --format=%s`
   per branch) via the Bash tool.

**Expected:**

- Claude presents the current worktree(s) — at minimum the main repo checkout — without erroring
  even if `.vibing/worktrees/` doesn't exist yet.

## 2. Create a worktree and continue in the same chat

**Steps:**

1. In a chat, send: "let's split fixing the auth session bug off into its own worktree."
2. Observe Claude propose a branch name (e.g. `fix-auth-session-bug`), run
   `git worktree add -b fix-auth-session-bug .vibing/worktrees/fix-auth-session-bug`, then edit
   its own chat file's `working_dir` frontmatter field.
3. Send a follow-up message, e.g. "what directory are you in now?"

**Expected:**

- `.vibing/worktrees/fix-auth-session-bug/` exists on disk (`git worktree list --porcelain`
  shows it).
- The chat file's frontmatter now has `working_dir: .vibing/worktrees/fix-auth-session-bug`.
- The follow-up message's response reflects the new worktree's directory, not the main repo root.
- No new chat buffer was opened — the same chat file continued.

## 3. Attach a new chat to an existing worktree

**Steps:**

1. With the worktree from Scenario 2 still present, open a brand-new chat.
2. Send: "what worktrees are there? I want to go into the auth one."

**Expected:**

- Claude lists the existing worktree(s), including `fix-auth-session-bug`.
- After the user confirms, Claude edits the new chat's own `working_dir` frontmatter to
  `.vibing/worktrees/fix-auth-session-bug` (no `git worktree add` — it already exists).
- A follow-up message in this new chat operates in that worktree.

## 4. Finish a worktree — clean removal

**Steps:**

1. In the worktree-attached chat from Scenario 2 or 3, commit or discard any changes so the
   worktree is clean.
2. Send: "clean up this worktree, I'm done."

**Expected:**

- Claude runs `git worktree remove .vibing/worktrees/fix-auth-session-bug` (no `--force`).
- `git worktree list --porcelain` no longer shows it, and the directory is gone from disk.
- If this was the chat's own `working_dir`, that frontmatter field is cleared (chat reverts to
  operating in the main repo root).

## 5. Finish a worktree — refused due to uncommitted changes

**Steps:**

1. Create a worktree per Scenario 2, then make an uncommitted change inside it (e.g. edit a
   file) without committing or stashing.
2. Send: "clean up this worktree."

**Expected:**

- `git worktree remove` fails because of the uncommitted change.
- Claude surfaces the exact git error to the user and does **not** retry with `--force`.
- The worktree and the uncommitted change are both still present after this exchange.

## 6. Attach/create with no `vibing-nvim` MCP connection

**Steps:**

1. Start a chat with the `vibing-nvim` MCP server unavailable (e.g. no running Neovim RPC
   server on the configured port).
2. Send: "split this into its own worktree."

**Expected:**

- Claude still creates the worktree on disk via `git worktree add`.
- Since `nvim_get_info` isn't available, Claude does not attempt to edit chat frontmatter it
  can't locate — it tells the user the worktree's path and that `working_dir` needs to be set
  by hand (or a new chat opened there).

## Manual verification checklist

- [ ] Scenario 1: listing works with zero and with one-or-more worktrees present
- [ ] Scenario 2: create updates the _same_ chat's frontmatter, no new buffer
- [ ] Scenario 3: attach works from a brand-new chat's first message
- [ ] Scenario 4: finish removes the worktree and clears `working_dir` when applicable
- [ ] Scenario 5: finish refuses (no `--force`) when there are uncommitted changes
- [ ] Scenario 6: MCP-unavailable fallback degrades gracefully instead of erroring
