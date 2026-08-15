---
name: vibing-worktree-run
description: Get a git worktree branch's code actually running (dev server, tests, CLI invocation, etc.) without merging or rebasing it, for vibing.nvim chats. Use when the user wants to run or try out a worktree branch for real ("I want to check this branch really works", "let me try this worktree's code for real", "run this worktree in the main directory").
---

# vibing-worktree-run

Merging or rebasing is out of scope here, and so is judging whether the result is correct — the
goal is only to get a worktree branch's code into a state where it can actually be executed,
temporarily, without touching git history. The right technique depends on whether this project's
tooling requires the repo to live at one fixed absolute path; investigate that once per project
and remember the answer instead of re-deriving it every time.

1. Read `.vibing/system-prompt.md` at the git root (vibing.nvim auto-creates it, empty, the first
   time a project chat is opened — it's gitignored and local-only, so don't expect it in `git
status` or try to commit it). Look for a `## Worktree run method` section.
   - **If present**: follow the documented method exactly and skip straight to running it —
     do not re-investigate.
   - **If absent** (or the file doesn't exist yet): continue to step 2.
2. Investigate what this project actually needs, cheapest option first:
   1. **Default — no path-swap needed.** A worktree is a fully independent, working checkout.
      Try running the project's normal command (test suite, dev server, build, CLI invocation,
      whatever the project normally uses) directly from inside the worktree directory. This is
      sufficient for the large majority of projects.
   2. **Fixed-path dependency.** Only reach for this if 2.1 provably doesn't work because some
      tool hardcodes an absolute path to the repo root (an editor plugin manager's `dir =`
      config, a daemon watching one fixed path, a docker-compose bind mount, etc.). Decide
      between two techniques based on whether that tool resolves symlinks to their real path:
      - **Symlink swap** (fast, non-destructive; silently wrong for tools that resolve to the
        canonical/real path): make the fixed path a symlink once, repoint it at the worktree to
        run, repoint it back at the main checkout when done.
      - **Checkout swap** (slower, but always correct regardless of tool internals): temporarily
        `git worktree remove <path>` (only when clean — never `--force`), `git checkout <branch>`
        in the main directory, run it, `git checkout` back to the original branch, then
        `git worktree add <path> <branch>` to restore the worktree.
        When genuinely unsure which technique the project's tooling needs, ask the user rather than
        guessing.
3. Record the decided method under a `## Worktree run method` heading in
   `.vibing/system-prompt.md` (`Edit` to append, or `Write` if the file is still empty) so future
   turns and sessions reuse it without re-investigating. Keep the note short and concrete — the
   actual command(s) to run, not prose about the investigation that produced it.
