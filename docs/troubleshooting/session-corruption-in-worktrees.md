# Session Corruption in Git Worktrees

## Problem Description

When using vibing.nvim in both main worktree and git worktrees simultaneously, sessions frequently become corrupted with the following error:

```
[vibing.nvim] Removing existing snapshot tag: claude-session-<uuid>

Session has been reset. Your next message will start a new session.
```

## Root Cause Analysis

The issue stems from **shared git tags across worktrees** combined with **separate session file locations**.

### Architecture Overview

vibing.nvim uses two separate storage mechanisms:

1. **Session Files** (JSONL format):
   - Location: `~/.claude/projects/<normalized-cwd>/<session-id>.jsonl`
   - Contains conversation history and messages
   - **Isolated per working directory** (separate for main vs worktree)

2. **Git Tags** (for snapshots):
   - Format: `claude-session-<session-id>`
   - Used by Agent SDK to tag git commits for session snapshots
   - **Shared across ALL worktrees** (same git repository)

### Path Normalization

The session directory is derived from the current working directory (cwd) by replacing `/` and `.` with `-`:

```typescript
// bin/agent-wrapper.ts
const normalizedCwd = cwd.replace(/[/.]/g, '-');
const sessionDir = join(homedir(), '.claude', 'projects', normalizedCwd);
```

**Example:**

```
Main worktree:
  cwd: /Users/shaba/workspaces/nvim-plugins/vibing.nvim
  normalized: -Users-shaba-workspaces-nvim-plugins-vibing-nvim
  session dir: ~/.claude/projects/-Users-shaba-workspaces-nvim-plugins-vibing-nvim/

Git worktree:
  cwd: /Users/shaba/workspaces/nvim-plugins/vibing.nvim/.worktrees/add-worktree-support-tzsWM
  normalized: -Users-shaba-workspaces-nvim-plugins-vibing-nvim--worktrees-add-worktree-support-tzsWM
  session dir: ~/.claude/projects/-Users-shaba-workspaces-nvim-plugins-vibing-nvim--worktrees-add-worktree-support-tzsWM/
```

**Result:** Session files are stored in **different directories**.

### The Conflict Scenario

```text
┌────────────────────────────────────────────────────────────────┐
│ Main Worktree                                                   │
│  ├─ Session files: ~/.claude/projects/...-vibing-nvim/         │
│  │   └─ session-abc.jsonl ✅ (unique)                          │
│  │                                                              │
│  └─ Git tags: shared repository                                │
│      └─ claude-session-abc ✅                                   │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│ Git Worktree (.worktrees/branch-name)                          │
│  ├─ Session files: ~/.claude/projects/...-worktrees-branch/    │
│  │   └─ session-abc.jsonl ✅ (unique, separate location)       │
│  │                                                              │
│  └─ Git tags: shared repository ⚠️                             │
│      └─ claude-session-abc ⚠️ (CONFLICT!)                      │
└────────────────────────────────────────────────────────────────┘

Problem:
  - Session files are isolated (different paths) ✅
  - Git tags are shared (same repository) ❌
  - Same session ID used in both environments → tag collision
```

### Detailed Sequence of Events

1. **Main worktree session starts:**
   - Session ID: `abc123`
   - Session file: `~/.claude/projects/...-vibing-nvim/abc123.jsonl`
   - Git tag created: `claude-session-abc123`

2. **Worktree session resumes same ID:**
   - Session ID: `abc123` (reused from saved chat file)
   - Session file: `~/.claude/projects/...-worktrees-branch/abc123.jsonl` (different location)
   - Attempts to create git tag: `claude-session-abc123`
   - **Conflict:** Tag already exists from main worktree!

3. **Agent SDK behavior on tag conflict:**
   - Agent SDK detects existing tag
   - Assumes session is corrupted (tag exists but doesn't match expected state)
   - Deletes existing tag: `git tag -d claude-session-abc123`
   - Resets session in main worktree ❌
   - Creates new session in worktree

4. **Result:**
   - Main worktree session is invalidated
   - User sees "Session has been reset" error
   - Worktree session continues with new ID

### Why This Happens

Git worktrees share:

- ✅ Git objects (commits, trees, blobs)
- ✅ Git config
- ✅ **Git tags** ← This is the problem!
- ✅ Branches
- ✅ Remotes

Git worktrees do NOT share:

- ❌ Working directory files
- ❌ Index (staging area)
- ❌ HEAD reference
- ❌ Checked out branch

Since git tags are shared, creating `claude-session-abc123` in worktree affects the main worktree's tags.

## Evidence

### Session File Isolation

```bash
$ ls ~/.claude/projects/-Users-shaba-workspaces-nvim-plugins-vibing-nvim/ | wc -l
4468  # Main worktree sessions

$ ls ~/.claude/projects/-Users-shaba-workspaces-nvim-plugins-vibing-nvim--worktrees-add-worktree-support-tzsWM/ | wc -l
24    # Worktree sessions (separate directory)
```

### Git Tag Sharing

```bash
$ cd /Users/shaba/workspaces/nvim-plugins/vibing.nvim
$ git tag | grep claude-session | wc -l
11    # Tags are visible in main worktree

$ cd .worktrees/add-worktree-support-tzsWM
$ git tag | grep claude-session | wc -l
11    # Same tags visible in worktree (shared!)
```

## Code Reference

The tag deletion logic that triggers the error:

```typescript
// bin/agent-wrapper.ts:120-137
// Pre-emptively delete existing snapshot tag to avoid duplication error
try {
  const { execSync } = await import('child_process');
  const tagName = `claude-session-${config.sessionId}`;

  // Check if tag exists
  const tagExists = execSync(`git tag -l "${tagName}"`, {
    cwd: config.cwd,
    encoding: 'utf8',
  }).trim();

  if (tagExists) {
    console.error(`[vibing.nvim] Removing existing snapshot tag: ${tagName}`);
    execSync(`git tag -d ${tagName}`, { cwd: config.cwd, stdio: 'ignore' });
  }
} catch (error) {
  // Ignore errors from tag deletion
}
```

## Potential Solutions

### Option 1: Namespace Tags by Worktree (Recommended)

Include worktree path in tag name:

```typescript
// Instead of:
const tagName = `claude-session-${sessionId}`;

// Use:
const worktreeId = hashWorktreePath(cwd); // e.g., "main" or "worktree-abc"
const tagName = `claude-session-${worktreeId}-${sessionId}`;
```

**Pros:**

- Complete isolation between worktrees
- No tag conflicts
- Existing sessions continue working

**Cons:**

- Requires Agent SDK support for custom tag naming (may not be possible)

### Option 2: Use Lightweight Tags with Worktree Prefix

```bash
# Main worktree
git tag claude-session-main-abc123

# Worktree
git tag claude-session-worktree-abc123
```

**Pros:**

- Simple implementation
- Clear separation

**Cons:**

- Still requires Agent SDK customization

### Option 3: Disable Git Snapshots in Worktrees

Skip git tag creation when in worktree environment:

```typescript
// Detect if we're in a worktree
const isWorktree = cwd.includes('/.worktrees/');

if (!isWorktree) {
  // Only create tags in main worktree
  execSync(`git tag ${tagName}`, { cwd });
}
```

**Pros:**

- Simple to implement
- No tag conflicts

**Cons:**

- Worktree sessions lose snapshot functionality
- Different behavior between main and worktree

### Option 4: Always Generate Fresh Session IDs

Never reuse session IDs across environments:

```lua
-- lua/vibing/ui/chat_buffer.lua
-- When creating chat in worktree, force new session ID
if is_in_worktree() then
  frontmatter.session_id = nil  -- Force new session
end
```

**Pros:**

- No tag conflicts
- Each environment has independent sessions

**Cons:**

- Cannot resume sessions across worktrees
- User experience degradation

### Option 5: Scope Session Files by Git Root (Breaking Change)

Use git repository root instead of cwd for session directory:

```typescript
// Find git root
const gitRoot = execSync('git rev-parse --show-toplevel', { cwd }).trim();
const normalizedRoot = gitRoot.replace(/[/.]/g, '-');
const sessionDir = join(homedir(), '.claude', 'projects', normalizedRoot);
```

**Pros:**

- Main and worktree share same session directory
- Aligns with git tag sharing behavior
- Consistent session access

**Cons:**

- Breaking change (existing sessions won't be found)
- Main and worktree sessions mix in same directory

## Workarounds

### Temporary Workaround: Avoid Simultaneous Usage

**Best practice for now:**

- Use **either** main worktree **or** git worktree at a time
- Don't switch between them while sessions are active
- Close all chat buffers before switching environments

### Clean Up Corrupted Sessions

```bash
# Remove all session tags
git tag -d $(git tag | grep claude-session)

# Restart Neovim and create fresh sessions
```

## Related Issues

- Git worktrees documentation: https://git-scm.com/docs/git-worktree
- Agent SDK session management: (internal to @anthropic-ai/claude-agent-sdk)

## Conclusion

The session corruption issue is caused by **architectural mismatch** between:

- Session files: Isolated per worktree (based on cwd)
- Git tags: Shared across worktrees (git repository scope)

A fix requires either:

1. Namespacing git tags by worktree (Agent SDK change)
2. Scoping session files by git root (breaking change)
3. Disabling git snapshots in worktrees (feature loss)

Until a proper fix is implemented, **avoid using multiple worktrees simultaneously** with vibing.nvim.
