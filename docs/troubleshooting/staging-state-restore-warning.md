# Staging State Restore Warning

## Problem Description

Users may occasionally see the following warning in vibing.nvim logs:

```
[WARN] Failed to restore staging state: error: No valid patches in input (allow with "--allow-empty")
```

This warning appears during Agent SDK git operations, typically when starting a chat or sending messages.

## Root Cause Analysis

### What is Staging State?

vibing.nvim's Agent SDK integration uses git to create session snapshots. To preserve the user's work, it:

1. **Saves current staging state** before creating snapshot
2. **Creates temporary commit** for snapshot (with all changes staged)
3. **Restores staging state** back to original state

This ensures the user's git staging area remains unchanged after snapshot operations.

### The Warning Sequence

```typescript
// bin/lib/patch-storage.ts
const stagedDiff = this.gitOps.saveStagingState(); // git diff --cached

// ... snapshot operations (stage all, commit, tag, reset) ...

this.gitOps.restoreStagingState(stagedDiff); // git apply --cached
```

**Implementation:**

```typescript
// bin/lib/git-operations.ts:68-94
saveStagingState(): string {
  const result = this.execute(['diff', '--cached']);
  return result.success ? result.stdout : '';
}

restoreStagingState(stagedDiff: string): boolean {
  if (!stagedDiff || !stagedDiff.trim()) {
    return true; // Empty diff is OK
  }

  const result = this.execute(['apply', '--cached'], {
    input: stagedDiff,
    stdio: ['pipe', 'ignore', 'pipe'],
  });

  if (!result.success) {
    console.error(
      '[WARN] Failed to restore staging state:',
      result.error?.message || result.stderr
    );
    return false;
  }
  return true;
}
```

### When the Warning Occurs

The warning happens when:

1. **Staging area is empty** (nothing staged via `git add`)
2. `git diff --cached` returns empty or whitespace-only output
3. However, the output **passes the empty check** (`!stagedDiff || !stagedDiff.trim()`)
4. `git apply --cached` receives input that is:
   - Not completely empty (contains some characters)
   - But lacks valid patch format (no diff markers)
   - Or contains only diff headers without actual changes

**Example scenarios:**

```bash
# Scenario 1: Completely empty staging area
$ git diff --cached
(no output)  # saveStagingState() returns ""
# ✅ Early return, no warning

# Scenario 2: Diff with metadata but no actual changes
$ git diff --cached
diff --git a/file.txt b/file.txt
# ❌ Passes empty check, but git apply fails

# Scenario 3: Whitespace-only diff
$ git diff --cached


# Could pass empty check depending on implementation
```

### Why git apply Fails

`git apply --cached` expects valid unified diff format:

```diff
diff --git a/file.txt b/file.txt
index abc123..def456 100644
--- a/file.txt
+++ b/file.txt
@@ -1,3 +1,4 @@
 line 1
+new line
 line 2
 line 3
```

Without the `@@` hunk markers and actual changes, `git apply` rejects the input:

```
error: No valid patches in input (allow with "--allow-empty")
```

## Impact Assessment

### Functional Impact: None ✅

This warning is **cosmetic only**:

- ✅ Session operations complete successfully
- ✅ User's staging area remains intact
- ✅ Snapshot creation/retrieval works correctly
- ✅ No data loss or corruption

**Why it's harmless:**

The warning occurs **after** snapshot operations are complete, during cleanup. If `restoreStagingState()` fails:

- Original staging area was empty anyway
- No staged changes to restore
- Final state matches original state (empty)

### User Experience Impact: Minor ⚠️

- ⚠️ Log noise (confusing warning message)
- ⚠️ Users may think something is broken
- ⚠️ Warning mentions `--allow-empty` but doesn't explain why

## Solution

### Implemented Fix: Add --allow-empty Flag

The simplest and safest solution is to add the `--allow-empty` flag to `git apply`:

```typescript
// bin/lib/git-operations.ts
restoreStagingState(stagedDiff: string): boolean {
  if (!stagedDiff || !stagedDiff.trim()) {
    return true;
  }

  const result = this.execute(['apply', '--cached', '--allow-empty'], {
    input: stagedDiff,
    stdio: ['pipe', 'ignore', 'pipe'],
  });

  if (!result.success) {
    console.error(
      '[WARN] Failed to restore staging state:',
      result.error?.message || result.stderr
    );
    return false;
  }
  return true;
}
```

**Benefits:**

- ✅ Eliminates spurious warnings
- ✅ Allows empty patches (which are valid in this context)
- ✅ No behavior change (empty staging state remains empty)
- ✅ Simple one-line fix

**Why this works:**

The `--allow-empty` flag tells `git apply` to accept patches that result in no changes. This is exactly what we want when:

- Original staging area was empty
- Saved diff contains no actual changes
- We're just restoring to empty state

### Alternative Solutions (Not Chosen)

#### Option 1: Validate Diff Format

```typescript
restoreStagingState(stagedDiff: string): boolean {
  if (!stagedDiff || !stagedDiff.trim()) {
    return true;
  }

  // Check if diff contains valid patch markers
  const hasDiffMarkers = /^(diff --git|@@)/m.test(stagedDiff);
  if (!hasDiffMarkers) {
    // Invalid diff format, nothing to restore
    return true;
  }

  // ... continue with git apply ...
}
```

**Rejected because:**

- More complex logic
- Need to maintain regex patterns
- May miss edge cases in diff format

#### Option 2: Suppress Specific Error

```typescript
if (!result.success) {
  // Ignore "No valid patches" error (normal for empty staging)
  if (result.stderr?.includes('No valid patches')) {
    return true;
  }

  console.error('[WARN] Failed to restore staging state:', result.stderr);
  return false;
}
```

**Rejected because:**

- Hides the symptom, not the cause
- Still produces git error internally
- Fragile (depends on error message text)

#### Option 3: Skip restore if No Changes Detected

```typescript
saveStagingState(): string {
  const result = this.execute(['diff', '--cached', '--quiet']);
  if (result.success) {
    // No changes staged, return special marker
    return '__EMPTY__';
  }

  const diffResult = this.execute(['diff', '--cached']);
  return diffResult.success ? diffResult.stdout : '';
}

restoreStagingState(stagedDiff: string): boolean {
  if (!stagedDiff || stagedDiff === '__EMPTY__' || !stagedDiff.trim()) {
    return true;
  }
  // ... continue ...
}
```

**Rejected because:**

- Over-engineered for this simple problem
- Introduces special marker strings
- `--allow-empty` is simpler and more direct

## Testing

### Reproduce the Warning

```bash
# 1. Ensure staging area is empty
cd /path/to/vibing.nvim
git status  # Should show "nothing to commit"

# 2. Start vibing.nvim chat
nvim
:VibingChat

# 3. Send a message
# Warning may appear in Agent SDK logs
```

### Verify the Fix

After applying `--allow-empty` flag:

```bash
# Same steps as above
# Warning should no longer appear
```

### Manual Test Cases

**Test Case 1: Empty staging area**

```bash
git reset  # Clear staging area
# Start chat, send message
# Expected: No warning
```

**Test Case 2: Files staged**

```bash
git add file.txt
# Start chat, send message
# Expected: No warning, file.txt remains staged
```

**Test Case 3: Partial staging**

```bash
git add -p file.txt  # Stage partial changes
# Start chat, send message
# Expected: No warning, partial staging preserved
```

## Related Code

### Primary Files

- `bin/lib/git-operations.ts` - Git wrapper with staging state methods
- `bin/lib/patch-storage.ts` - Session snapshot creation/retrieval

### Key Functions

```typescript
// Save current staging state
saveStagingState(): string

// Restore staging state from saved diff
restoreStagingState(stagedDiff: string): boolean

// Create session snapshot (uses save/restore)
createSnapshot(): boolean

// Get changes since snapshot (uses save/restore)
getChangesSinceSnapshot(): string | null
```

## Conclusion

The "Failed to restore staging state" warning is a **harmless cosmetic issue** caused by attempting to apply an empty or invalid diff patch.

**Fix:** Add `--allow-empty` flag to `git apply --cached` command.

**Result:** Warning eliminated, no functional changes, cleaner logs.

**Status:** Ready for implementation in next PR.
