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
