# Jujutsu-based Patch Generation Implementation Plan

## Overview

Replace git-based patch generation with jujutsu (jj) for more streamlined snapshot and diff workflow.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Node.js Process (agent-wrapper.ts)                       │
│                                                           │
│  ┌─────────────────────────────────────────────────┐    │
│  │ VCS Adapter Interface                            │    │
│  │  - takeSnapshot(): boolean                       │    │
│  │  - generatePatch(): string | null                │    │
│  │  - clear(): void                                 │    │
│  └─────────────────────────────────────────────────┘    │
│           ↑                          ↑                   │
│           │                          │                   │
│  ┌────────────────┐        ┌────────────────┐           │
│  │ GitOperations  │        │ JjOperations   │           │
│  │ (existing)     │        │ (new)          │           │
│  └────────────────┘        └────────────────┘           │
│                                                           │
│  ┌─────────────────────────────────────────────────┐    │
│  │ PatchStorage                                     │    │
│  │  - vcsBackend: 'git' | 'jujutsu'                │    │
│  │  - adapter: VCSAdapter                          │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

## Jujutsu Workflow

### 1. Snapshot Creation

**Git approach:**
```bash
git add -A
git commit --allow-empty -m "SNAPSHOT"
git tag vibing-patch-<session-id>
git reset --mixed HEAD~1
```

**Jujutsu approach:**
```bash
# Option 1: Use change ID directly (no tag needed)
jj commit -m "SNAPSHOT_<session-id>"
# Store the change ID for later comparison

# Option 2: Use bookmarks (similar to git tags)
jj bookmark create vibing-patch-<session-id>

# No reset needed - jj automatically creates new working-copy commit
```

### 2. Patch Generation

**Git approach:**
```bash
git add -A
git diff --cached --relative <tag>
git reset --mixed HEAD
```

**Jujutsu approach:**
```bash
# Option 1: Diff against change ID
jj diff --from <change-id>

# Option 2: Diff against bookmark
jj diff --from vibing-patch-<session-id>

# No staging/unstaging needed
```

### 3. Cleanup

**Git approach:**
```bash
git tag -d vibing-patch-<session-id>
```

**Jujutsu approach:**
```bash
# Option 1: Nothing needed (change ID cleanup happens automatically)

# Option 2: Remove bookmark
jj bookmark delete vibing-patch-<session-id>
```

## Implementation Steps

### Step 1: Create VCS Adapter Interface

```typescript
// bin/lib/vcs-adapter.ts
export interface VCSAdapter {
  takeSnapshot(sessionId: string): boolean;
  generatePatch(): string | null;
  clear(): void;
  isAvailable(): boolean;
}
```

### Step 2: Implement JjOperations

```typescript
// bin/lib/jj-operations.ts
import { spawnSync } from 'child_process';

interface JjResult {
  success: boolean;
  stdout: string;
  stderr: string;
  error?: Error;
}

class JjOperations implements VCSAdapter {
  private cwd: string;
  private snapshotChangeId: string | null = null;
  private defaultTimeout: number;

  constructor(cwd: string, options: { timeout?: number } = {}) {
    this.cwd = cwd;
    this.defaultTimeout = options.timeout || 30000;
  }

  execute(args: string[], options = {}): JjResult {
    const result = spawnSync('jj', args, {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: this.defaultTimeout,
      ...options,
    });

    return {
      success: result.error == null && result.status === 0,
      stdout: result.stdout || '',
      stderr: result.stderr || '',
      error: result.error,
    };
  }

  isAvailable(): boolean {
    const result = this.execute(['--version']);
    return result.success;
  }

  takeSnapshot(sessionId: string): boolean {
    // Create a snapshot commit
    const commitResult = this.execute([
      'commit',
      '-m',
      `CLAUDE_SESSION_SNAPSHOT_${sessionId}`,
    ]);

    if (!commitResult.success) {
      console.error('[ERROR] Failed to create snapshot commit:', commitResult.stderr);
      return false;
    }

    // Get the change ID of the snapshot commit (parent of working-copy)
    const changeIdResult = this.execute(['log', '-r', '@-', '-T', 'change_id']);
    if (!changeIdResult.success) {
      console.error('[ERROR] Failed to get change ID:', changeIdResult.stderr);
      return false;
    }

    this.snapshotChangeId = changeIdResult.stdout.trim();

    // Create bookmark for easier reference
    const bookmarkResult = this.execute([
      'bookmark',
      'create',
      `vibing-patch-${sessionId}`,
      '-r',
      '@-',
    ]);

    if (!bookmarkResult.success) {
      console.error('[WARN] Failed to create bookmark:', bookmarkResult.stderr);
      // Continue anyway - we can use change ID
    }

    return true;
  }

  generatePatch(): string | null {
    if (!this.snapshotChangeId) {
      console.error('[ERROR] Cannot generate patch: no snapshot change ID');
      return null;
    }

    // Generate diff from snapshot to current working-copy
    const diffResult = this.execute(['diff', '--from', this.snapshotChangeId]);

    if (!diffResult.success) {
      console.error('[ERROR] Failed to generate diff:', diffResult.stderr);
      return null;
    }

    const patchContent = diffResult.stdout.trim() || null;
    return patchContent;
  }

  clear(): void {
    if (!this.snapshotChangeId) {
      return;
    }

    // Remove bookmark if it exists
    this.execute(['bookmark', 'delete', `vibing-patch-*`], {
      stdio: ['ignore', 'ignore', 'ignore'],
    });

    this.snapshotChangeId = null;
  }

  /**
   * Detect if current directory is in a jujutsu worktree.
   */
  detectWorktree(): { isWorktree: boolean; worktreeName: string | null } {
    // TODO: Implement jj worktree detection
    // For now, return false (jj doesn't have worktree concept like git)
    return { isWorktree: false, worktreeName: null };
  }
}

export default JjOperations;
```

### Step 3: Update PatchStorage to Support Both

```typescript
// bin/lib/patch-storage.ts
import GitOperations from './git-operations.js';
import JjOperations from './jj-operations.js';
import type { VCSAdapter } from './vcs-adapter.js';

class PatchStorage {
  private sessionId: string | null = null;
  private cwd: string;
  private vcsBackend: 'git' | 'jujutsu' = 'git';
  private adapter: VCSAdapter;

  constructor(options: { backend?: 'git' | 'jujutsu' } = {}) {
    this.cwd = process.cwd();
    this.vcsBackend = options.backend || this.detectVCS();
    this.adapter = this.createAdapter();
  }

  private detectVCS(): 'git' | 'jujutsu' {
    // Check if jj is available and current dir is jj repo
    const jjOps = new JjOperations(this.cwd);
    if (jjOps.isAvailable()) {
      const result = jjOps.execute(['root']);
      if (result.success) {
        return 'jujutsu';
      }
    }

    // Default to git
    return 'git';
  }

  private createAdapter(): VCSAdapter {
    if (this.vcsBackend === 'jujutsu') {
      return new JjOperations(this.cwd, { timeout: 30000 });
    }
    return new GitOperations(this.cwd, { timeout: 30000 });
  }

  takeSnapshot(): boolean {
    if (!this.sessionId) {
      console.error('[ERROR] Cannot take snapshot: session ID not set');
      return false;
    }
    return this.adapter.takeSnapshot(this.sessionId);
  }

  generatePatch(): string | null {
    return this.adapter.generatePatch();
  }

  clear(): void {
    this.adapter.clear();
  }

  // ... rest of PatchStorage methods remain the same
}
```

### Step 4: Configuration

```lua
-- lua/vibing/config.lua
{
  vcs = {
    backend = "auto",  -- "auto" | "git" | "jujutsu"
  }
}
```

## Benefits of Jujutsu Implementation

1. **Simpler workflow** - No staging/unstaging needed
2. **Automatic tracking** - Working-copy is always a commit
3. **Better history** - `jj obslog` shows all changes including snapshots
4. **No tag pollution** - Can use change IDs instead of tags
5. **Safer operations** - jj prevents data loss by design

## Migration Strategy

1. **Phase 1**: Implement alongside git (keep both)
2. **Phase 2**: Auto-detect which VCS is in use
3. **Phase 3**: Allow manual override via config
4. **Phase 4**: Deprecate git if jujutsu proves stable

## Testing

```bash
# Test jj operations
cd test-repo
jj init
# ... create test files ...
jj commit -m "initial"

# Test snapshot workflow
node dist/bin/agent-wrapper.js --vcs-backend jujutsu --prompt "edit file"

# Verify patch generation
cat .vibing/patches/<session-id>/*.patch
```

## Compatibility

**Git repositories**: Continue using `GitOperations` (no change)
**Jujutsu repositories**: Automatically use `JjOperations`
**Hybrid setup**: User can force backend via config

## Open Questions

1. Should we support jj workspaces similar to git worktrees?
2. How to handle jj-specific features (e.g., conflict markers)?
3. Should snapshots be visible in `jj log` or hidden?
4. Performance comparison between git and jj for large repos?

## References

- [Jujutsu Documentation](https://github.com/martinvonz/jj)
- [Jujutsu vs Git Commands](https://github.com/martinvonz/jj/blob/main/docs/git-comparison.md)
- Current implementation: `bin/lib/patch-storage.ts`, `bin/lib/git-operations.ts`
