# Configuration

The full user-facing configuration reference (every `setup()` field, window positions, permission
rule examples, daily summary, etc.) lives in `handbook/configuration.md` and in
`lua/vibing/config.lua` (defaults + type annotations) — read those instead of duplicating the
field list here. `README.md` keeps only a short "commonly tweaked options" block that links to
`handbook/configuration.md`.

## Where Things Live

- Full option list & defaults: `handbook/configuration.md`
- Mote (diff tool) setup, session storage layout, and troubleshooting: `handbook/MIGRATION_MOTE.md`
- Defaults and type annotations: `lua/vibing/config.lua`

## Diff Tracking (Claude-relevant behavior)

`config.diff.tool` (`"git"` | `"mote"` | `"auto"`) selects the diff strategy used by `gd` (diff
viewer):

**Per-request tracking (default, `"auto"`/`"git"`):** the PreToolUse hook backs up a file's
pre-edit content before Write/Edit/MultiEdit/NotebookEdit, and a git-style patch is generated with
`vim.diff()` (built-in xdiff, no external process) after the response. Patches are stored under
`.vibing/patches/` and referenced per chat buffer via `<!-- patch: ... -->` comments, so `gd` and
patch revert work per request and per chat buffer — concurrent chats never mix diffs, and cost
scales with files actually touched, not tree size. Limitation: Bash-driven file changes have no
diff section (only mote catches those).

**mote (opt-in, `"mote"`):** vibing.nvim ships its own bundled mote binary per platform
(`bin/mote-<os>-<arch>`), falling back to a system `mote` only if the bundled one is unavailable.
All mote data is project-local, stored via `-d/--context-dir`, never `~/.config/mote/`:
`.vibing/mote/<project>/vibing-root/` for the main repo, and
`.vibing/mote/<project>/vibing-worktree-<branch>-<hash>/` per worktree. Contexts and `ignore`
files (`.vibing/`, `node_modules/`, `.git/`, ...) are created and updated automatically — no
manual `mote context new` step is needed. `gd` on a file path checks for patch files first, then
falls back to mote.
