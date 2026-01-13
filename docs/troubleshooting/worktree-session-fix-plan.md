# Worktree Session Fix: Implementation Plan

## Problem Summary

Currently, using vibing.nvim in both main worktree and git worktrees simultaneously causes session corruption due to git tag conflicts.

**Root Cause:**

- vibing.nvim's `patch-storage` creates tags: `claude-session-<uuid>`
- Git tags are shared across ALL worktrees (same repository)
- Same tag name in different worktrees → conflict → session reset

## Proposed Solution: Prefix Tags with Worktree Identifier

Add two prefixes to patch storage tags:

1. **Worktree identifier** - Distinguishes main vs worktree
2. **"patch" marker** - Distinguishes vibing.nvim tags from Agent SDK tags

### New Tag Format

```
vibing-patch-<worktree-id>-<session-id>
```

**Examples:**

```bash
# Main worktree
vibing-patch-main-abc123-def456-789

# Git worktree (.worktrees/feature-branch)
vibing-patch-wt-feature-branch-abc123-def456-789

# Git worktree (.worktrees/add-worktree-support-tzsWM)
vibing-patch-wt-add-worktree-support-tzsWM-abc123-def456-789
```

### Benefits

✅ **Complete isolation** - Each worktree has unique tag names
✅ **No conflicts** - Tags never collide
✅ **Clear naming** - Easy to identify vibing.nvim's patch tags
✅ **Backward compatible** - Old tags remain functional
✅ **Simultaneous usage** - Main and worktree can run concurrently

## Implementation

### 1. Detect Worktree Environment

```typescript
// bin/lib/git-operations.ts or bin/lib/worktree-utils.ts

/**
 * Detect if current directory is in a git worktree
 * @returns { isWorktree: boolean, worktreeName: string | null }
 */
function detectWorktree(cwd: string): { isWorktree: boolean; worktreeName: string | null } {
  try {
    const { execSync } = require('child_process');

    // Get git common dir (points to main worktree's .git)
    const gitCommonDir = execSync('git rev-parse --git-common-dir', {
      cwd,
      encoding: 'utf8',
    }).trim();

    // Get git dir (current worktree's .git)
    const gitDir = execSync('git rev-parse --git-dir', {
      cwd,
      encoding: 'utf8',
    }).trim();

    // If they differ, we're in a worktree
    if (gitCommonDir !== gitDir) {
      // Extract worktree name from path
      // e.g., /path/to/repo/.worktrees/feature-branch -> "feature-branch"
      const worktreePath = execSync('git rev-parse --show-toplevel', {
        cwd,
        encoding: 'utf8',
      }).trim();

      const pathParts = worktreePath.split('/');
      const worktreeName = pathParts[pathParts.length - 1];

      return { isWorktree: true, worktreeName };
    }

    return { isWorktree: false, worktreeName: null };
  } catch (error) {
    // Not a git repository or git command failed
    return { isWorktree: false, worktreeName: null };
  }
}
```

### 2. Generate Worktree-Specific Tag Name

```typescript
// bin/lib/patch-storage.ts

class PatchStorage {
  private sessionId: string | null = null;
  private snapshotTag: string | null = null;
  private worktreeInfo: { isWorktree: boolean; worktreeName: string | null } | null = null;

  setSessionId(sessionId: string): void {
    this.sessionId = sessionId;

    // Detect worktree environment
    this.worktreeInfo = detectWorktree(this.cwd);

    // Generate worktree-specific tag name
    const worktreeId = this.worktreeInfo.isWorktree
      ? `wt-${this.worktreeInfo.worktreeName}`
      : 'main';

    // New format: vibing-patch-<worktree-id>-<session-id>
    this.snapshotTag = `vibing-patch-${worktreeId}-${sessionId}`;
  }
}
```

**Tag Examples:**

```bash
# Main worktree
vibing-patch-main-abc123-def456-789

# Worktree: feature-branch
vibing-patch-wt-feature-branch-abc123-def456-789

# Worktree: add-worktree-support-tzsWM
vibing-patch-wt-add-worktree-support-tzsWM-abc123-def456-789
```

### 3. Update agent-wrapper.ts Tag Deletion

Currently, `agent-wrapper.ts` pre-emptively deletes tags to avoid conflicts. This logic should be updated to handle the new format:

```typescript
// bin/agent-wrapper.ts:120-134

if (config.sessionId) {
  try {
    const { execSync } = await import('child_process');

    // Detect worktree
    const worktreeInfo = detectWorktree(config.cwd);
    const worktreeId = worktreeInfo.isWorktree ? `wt-${worktreeInfo.worktreeName}` : 'main';

    // New vibing.nvim tag format
    const vibingTagName = `vibing-patch-${worktreeId}-${config.sessionId}`;

    // Check and delete vibing.nvim's patch tag
    const vibingTagExists = execSync(`git tag -l "${vibingTagName}"`, {
      cwd: config.cwd,
      encoding: 'utf8',
    }).trim();

    if (vibingTagExists) {
      console.error(`[vibing.nvim] Removing existing patch tag: ${vibingTagName}`);
      execSync(`git tag -d ${vibingTagName}`, { cwd: config.cwd, stdio: 'ignore' });
    }

    // Also check for old format tags (backward compatibility)
    const oldTagName = `claude-session-${config.sessionId}`;
    const oldTagExists = execSync(`git tag -l "${oldTagName}"`, {
      cwd: config.cwd,
      encoding: 'utf8',
    }).trim();

    if (oldTagExists) {
      console.error(`[vibing.nvim] Removing old format tag: ${oldTagName}`);
      execSync(`git tag -d ${oldTagName}`, { cwd: config.cwd, stdio: 'ignore' });
    }
  } catch (error) {
    // Ignore errors from tag deletion
  }
}
```

## Testing Plan

### Test Case 1: Main Worktree

```bash
# Start in main worktree
cd /path/to/vibing.nvim

# Create session
nvim
:VibingChat

# Send messages, generate patches
# Expected tag: vibing-patch-main-<session-id>

# Verify tag exists
git tag | grep vibing-patch-main
```

### Test Case 2: Git Worktree

```bash
# Create and enter worktree
git worktree add .worktrees/test-branch test-branch
cd .worktrees/test-branch

# Create session
nvim
:VibingChat

# Send messages, generate patches
# Expected tag: vibing-patch-wt-test-branch-<session-id>

# Verify tag exists
git tag | grep vibing-patch-wt-test-branch
```

### Test Case 3: Simultaneous Usage

```bash
# Terminal 1: Main worktree
cd /path/to/vibing.nvim
nvim
:VibingChat
# Send message -> creates vibing-patch-main-<id1>

# Terminal 2: Worktree
cd .worktrees/test-branch
nvim
:VibingChat
# Send message -> creates vibing-patch-wt-test-branch-<id2>

# Verify both tags exist without conflict
git tag | grep vibing-patch
# vibing-patch-main-<id1>
# vibing-patch-wt-test-branch-<id2>
```

### Test Case 4: Session Resume

```bash
# Create session in main
cd /path/to/vibing.nvim
nvim
:VibingChat
# Save chat file

# Reopen saved chat
nvim .vibing/chat-2025-01-13.vibing
# Expected: Session resumes with correct tag (vibing-patch-main-<id>)
```

### Test Case 5: Backward Compatibility

```bash
# Existing sessions with old tag format (claude-session-<id>)
# Should still work

# New sessions should use new format (vibing-patch-<worktree>-<id>)
```

## Migration Strategy

### For Existing Users

1. **Old tags remain functional** - No breaking changes
2. **New sessions use new format** - Automatic migration
3. **Cleanup old tags (optional)**:
   ```bash
   # Remove all old format tags
   git tag -d $(git tag | grep "^claude-session-")
   ```

### Backward Compatibility

The implementation should:

- ✅ Detect and handle old format tags (`claude-session-<id>`)
- ✅ Create new format tags for new sessions (`vibing-patch-<worktree>-<id>`)
- ✅ Support resuming sessions with either format

## Files to Modify

1. **`bin/lib/patch-storage.ts`**
   - `setSessionId()`: Generate worktree-specific tag name
   - Add worktree detection logic

2. **`bin/agent-wrapper.ts`**
   - Update tag deletion logic to handle new format
   - Add backward compatibility for old tags

3. **`bin/lib/git-operations.ts`** (or new `bin/lib/worktree-utils.ts`)
   - Add `detectWorktree()` utility function

## Agent SDK Tags (Out of Scope)

This fix only addresses **vibing.nvim's patch-storage tags**. Agent SDK's internal tags (if any) remain unaffected:

- ❌ Cannot modify Agent SDK's tag naming
- ❌ Cannot control session file locations
- ✅ vibing.nvim's patch storage becomes worktree-safe

If Agent SDK also creates `claude-session-<id>` tags, those conflicts remain. However, this fix ensures vibing.nvim's own functionality works correctly across worktrees.

## Summary

**Change:**

```diff
- Tag format: claude-session-<session-id>
+ Tag format: vibing-patch-<worktree-id>-<session-id>
```

**Benefits:**

- ✅ Main and worktree can be used simultaneously
- ✅ No tag conflicts
- ✅ Clear namespace separation
- ✅ Backward compatible

**Implementation effort:** Low (3 files, ~100 lines of code)

**Status:** Ready for implementation
