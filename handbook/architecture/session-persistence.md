# Session Persistence: the `working_dir` Boundary

Detail behind `.claude/rules/architecture.md` → "Session Persistence". The rules file states the
frontmatter schema and the invariant that `Git.resolve_working_dir` bounds `working_dir` to the
git root and returns `nil` rather than substituting the root. This is how that check is
implemented, and why neither half of it can be swapped for the obvious alternative.

Two things about that check are not interchangeable, both verified against the real functions
rather than read off the docs. `vim.fn.fnamemodify(path, ":p")` does **not** collapse `..` in a
path that is already absolute (`/a/b/../c` comes back unchanged), so it cannot do this job;
`vim.fn.resolve()` collapses `..` _and_ follows symlinks, and unlike `vim.uv.fs_realpath()` it
works on a path that does not exist yet. And the comparison is between physical paths on both
sides: `git rev-parse --show-toplevel` always reports the symlink-resolved path, which on macOS
is `/private/tmp/...` for anything under `/tmp`, so comparing it against an unresolved candidate
would reject directories that are genuinely inside. The boundary is decided on the resolved
form, but the string handed back is the plain `git_root .. "/" .. working_dir` — a chat whose
`working_dir` goes through a symlink keeps seeing the path it wrote.

## Who writes `working_dir` when a chat enters a worktree

`working_dir` is not a convenience. A chat that enters a worktree without it reports **no changes
at all**: the snapshot baseline stays on the parent repo, and `.vibing/` is excluded there, so the
whole turn's work falls outside the diff. Measured on a fixture — the same turn goes from 0 files
and no patch to 2 files and a 361-byte patch purely by pointing `working_dir` at the worktree.

That is too load-bearing to leave to a skill instruction, so `worktree_binding.lua` writes it.
`observe()` hangs off the PreToolUse handler next to the two diff baselines; `resolve()` runs at
the very end of `_handle_response`. Three things about the shape are deliberate.

**The worktree is identified by diffing `git worktree list` across the tool call**, not by reading
the Bash command. A parse has to survive `-b`, quoting and variable expansion, and when it loses,
the result is a chat pointed at a directory that was never created — strictly worse than not
writing at all. The before-list is captured once per turn, on the first matching tool; taking it
again would move a worktree created by the first command into the "already there" set.
`EnterWorktree`'s `path` is the one argument read directly, because entering an _existing_
worktree changes no list. If more than one worktree appears in a turn, nothing is written and the
user is told, because there is no honest way to pick.

**`resolve()` has to run after the diff is emitted.** `_finalize_request_diff` reads `working_dir`
live to compute its `base_dir`, so writing first pairs this turn's backups (taken relative to the
old cwd) with the new worktree's root.

**`ExitWorktree` only clears the field when it currently points at a worktree** — checked against
the same before-list. Clearing unconditionally would throw away a `working_dir` the user set for
an unrelated reason, and the tool is a documented no-op when no worktree session is active.
