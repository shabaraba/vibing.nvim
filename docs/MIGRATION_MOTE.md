# Migration Guide: Git-based Patches to mote

This guide explains the migration from git-based patch storage to mote-based patch storage in vibing.nvim.

## What Changed

### Removed Features

1. **Git-based patch storage** - The legacy Agent SDK patch system using git tags has been removed
2. **Legacy patch files** - Old patch files stored in `.vibing/patches/` are no longer automatically read
3. **Git tag management** - Automatic git tag cleanup for session management has been removed

### New Features

1. **mote integration** - All diff and patch operations now use [mote](https://github.com/shabaraba/mote)
2. **Session-based storage** - Each chat session gets its own isolated mote storage directory
3. **Automatic .moteignore** - `.vibing/.moteignore` is automatically created to exclude internal files

## Impact on Existing Users

### For Users Without mote

If you don't have mote installed and haven't used diff features:

- **No action required** - vibing.nvim will continue to work normally
- The `gd` keymap will fallback to `git diff` if available

### For Users With Existing Chat Sessions

If you have existing chat sessions with Agent SDK patches:

- **Old patches are no longer accessible** via the `gd` keymap
- Old chat sessions will start fresh mote storage when resumed
- No data loss - your chat history remains intact

### For Users Who Want mote Integration

To enable mote-based diff functionality:

1. **Install mote** (optional - vibing.nvim includes bundled binaries)

   ```bash
   # Homebrew (macOS / Linux)
   brew tap shabaraba/tap
   brew install mote

   # Or from source
   cargo install --path .
   ```

2. **Initialize mote** in your project (one-time setup, mote v0.2.0+)

   ```bash
   # For project root
   mote --project <project-name> context new vibing-root

   # For worktree (e.g., feature-x branch)
   mote --project <project-name> context new vibing-worktree-feature-x
   ```

3. **Configure vibing.nvim** (recommended settings)
   ```lua
   require("vibing").setup({
     diff = {
       tool = "auto",  -- Use mote if available, fallback to git
       mote = {
         ignore_file = ".vibing/.moteignore",
         project = nil,  -- nil = auto-detect from git repo name
         context_prefix = "vibing",  -- Context name prefix
       },
     },
   })
   ```

## Configuration Examples

### Minimal Configuration (auto-fallback)

```lua
require("vibing").setup({
  diff = {
    tool = "auto",  -- Automatically use mote if available
  },
})
```

### Force mote (show error if unavailable)

```lua
require("vibing").setup({
  diff = {
    tool = "mote",
  },
})
```

### Disable mote (use git only)

```lua
require("vibing").setup({
  diff = {
    tool = "git",
  },
})
```

## Session Storage Structure (mote v0.2.0+)

With mote integration, each chat session maintains isolated contexts:

```
~/.mote/
├── <project-name>/
│   ├── vibing-root/
│   │   ├── snapshots/
│   │   ├── objects/
│   │   └── patches/
│   │       └── 20250121_143000.patch
│   └── vibing-worktree-feature-x/
│       ├── snapshots/
│       ├── objects/
│       └── patches/
```

**Note:** mote v0.2.0+ stores data in `~/.mote/<project>/<context>` by default. The context names are:

- Project root: `vibing-root`
- Worktrees: `vibing-worktree-<branch>`

**Benefits:**

- Session isolation - Changes in different contexts don't interfere
- Automatic cleanup - Old contexts can be safely removed with `mote context delete`
- Fine-grained history - More granular than git commits

## Troubleshooting

### "mote not initialized" error

**Solution:** Initialize mote context in your project (mote v0.2.0+):

```bash
# For project root
mote --project <project-name> context new vibing-root

# For worktree (e.g., feature-x)
mote --project <project-name> context new vibing-worktree-feature-x
```

### "No mote snapshot found" when pressing `gd`

**Cause:** The file hasn't been modified since the last snapshot.

**Solution:** Make changes to the file, or manually create a snapshot (mote v0.2.0+):

```bash
# For project root
mote --project <project-name> --context vibing-root snapshot -m "Manual snapshot"

# For worktree
mote --project <project-name> --context vibing-worktree-<branch> snapshot -m "Manual snapshot"
```

### Old patches not visible with `gd`

**Cause:** Legacy git-based patches are no longer supported.

**Workaround:** Use `git diff` manually to view old changes:

```bash
git diff <old-commit>
```

## Benefits of mote Over Git Patches

1. **Finer granularity** - Snapshots at any point, not just commits
2. **Session isolation** - Each chat session has independent history
3. **No git pollution** - Doesn't create temporary git tags or branches
4. **Content-addressable** - Efficient deduplication of unchanged content
5. **Works with any VCS** - Not limited to git repositories

## Rollback (Not Recommended)

If you need to temporarily revert to older behavior:

1. Checkout the previous version before this migration
2. Note that old sessions won't work with the new version

## Questions or Issues?

- Check the [mote documentation](https://github.com/shabaraba/mote)
- Open an issue at [vibing.nvim issues](https://github.com/shabaraba/vibing.nvim/issues)
