/**
 * Snapshot-based patch generation for Claude sessions.
 * Flow: takeSnapshot() creates git commit -> Claude works -> generatePatch() compares current state
 */

import { writeFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';
import { spawnSync } from 'child_process';
import { homedir } from 'os';

class PatchStorage {
  constructor() {
    this.sessionId = null;
    this.cwd = process.cwd();
    this.saveLocationType = 'project';
    this.saveDir = null;
    this.snapshotTag = null; // git tag for snapshot commit
  }

  setSessionId(sessionId) {
    this.sessionId = sessionId;
    this.snapshotTag = `claude-session-${sessionId}`;
  }

  setCwd(cwd) {
    this.cwd = cwd;
  }

  setSaveConfig(saveLocationType, saveDir) {
    this.saveLocationType = saveLocationType || 'project';
    this.saveDir = saveDir;
  }

  /**
   * Save current staging state to restore later
   */
  saveStagingState() {
    const result = spawnSync('git', ['diff', '--cached'], {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    return result.status === 0 ? result.stdout : '';
  }

  /**
   * Restore staging state from saved diff
   */
  restoreStagingState(stagedDiff) {
    if (!stagedDiff || !stagedDiff.trim()) {
      return;
    }

    const result = spawnSync('git', ['apply', '--cached'], {
      cwd: this.cwd,
      input: stagedDiff,
      encoding: 'utf-8',
      stdio: ['pipe', 'ignore', 'ignore'],
    });

    if (result.error) {
      console.error('[WARN] Failed to restore staging state:', result.error.message);
    }
  }

  /**
   * Create snapshot commit with current state (including unstaged/untracked)
   * This becomes the baseline for comparison at session end
   */
  takeSnapshot() {
    if (!this.sessionId) {
      console.error('[ERROR] Cannot take snapshot: sessionId not set');
      return false;
    }

    // 1. Save current staging state
    const stagedDiff = this.saveStagingState();

    // 2. Check for merge/rebase conflicts
    if (existsSync(join(this.cwd, '.git', 'MERGE_HEAD'))) {
      console.error('[ERROR] Cannot take snapshot during merge/rebase');
      return false;
    }

    // 3. Stage everything (including untracked files)
    const addResult = spawnSync('git', ['add', '-A'], {
      cwd: this.cwd,
      stdio: 'ignore',
    });
    if (addResult.error) {
      console.error('[ERROR] Failed to stage files:', addResult.error.message);
      this.restoreStagingState(stagedDiff);
      return false;
    }

    // 4. Create snapshot commit (skip pre-commit hooks)
    const commitResult = spawnSync(
      'git',
      [
        'commit',
        '--quiet',
        '--allow-empty',
        '--no-verify',
        '-m',
        `CLAUDE_SESSION_SNAPSHOT_${this.sessionId}`,
      ],
      { cwd: this.cwd, stdio: 'ignore' }
    );
    if (commitResult.error) {
      console.error('[ERROR] Failed to create snapshot commit:', commitResult.error.message);
      this.restoreStagingState(stagedDiff);
      return false;
    }

    // 5. Tag the snapshot commit for protection from gc
    const tagResult = spawnSync('git', ['tag', this.snapshotTag], {
      cwd: this.cwd,
      stdio: 'ignore',
    });
    if (tagResult.error) {
      console.error('[ERROR] Failed to tag snapshot:', tagResult.error.message);
    }

    // 6. Reset to original state (remove commit, keep changes)
    spawnSync('git', ['reset', '--soft', 'HEAD~1'], {
      cwd: this.cwd,
      stdio: 'ignore',
    });

    // 7. Clear staging area
    spawnSync('git', ['reset', 'HEAD', '--quiet'], {
      cwd: this.cwd,
      stdio: 'ignore',
    });

    // 8. Restore original staging state
    this.restoreStagingState(stagedDiff);

    return true;
  }

  /**
   * Generate patch by comparing current state with snapshot
   * No need to track individual files - just compare everything
   */
  generatePatch() {
    if (!this.snapshotTag) {
      console.error('[ERROR] Cannot generate patch: no snapshot tag');
      return null;
    }

    // 1. Save current staging state
    const stagedDiff = this.saveStagingState();

    // 2. Stage everything to capture current state
    const addResult = spawnSync('git', ['add', '-A'], {
      cwd: this.cwd,
      stdio: 'ignore',
    });
    if (addResult.error) {
      console.error('[ERROR] Failed to stage files for patch:', addResult.error.message);
      return null;
    }

    // 3. Generate diff from snapshot tag
    const diffResult = spawnSync('git', ['diff', '--cached', this.snapshotTag], {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    const patchContent = diffResult.status === 0 ? diffResult.stdout?.trim() : null;

    // 4. Clear staging area
    spawnSync('git', ['reset', 'HEAD', '--quiet'], {
      cwd: this.cwd,
      stdio: 'ignore',
    });

    // 5. Restore original staging state
    this.restoreStagingState(stagedDiff);

    return patchContent || null;
  }

  getPatchesBaseDir() {
    switch (this.saveLocationType) {
      case 'user':
        return join(homedir(), '.local', 'share', 'nvim', 'vibing', 'patches');
      case 'custom': {
        const basePath = (this.saveDir || join(this.cwd, '.vibing')).replace(/\/chats?\/?$/, '');
        return join(basePath, 'patches');
      }
      default:
        return join(this.cwd, '.vibing', 'patches');
    }
  }

  savePatchToFile(patchContent) {
    if (!patchContent || !this.sessionId) {
      return null;
    }

    try {
      const patchDir = join(this.getPatchesBaseDir(), this.sessionId);
      mkdirSync(patchDir, { recursive: true });

      const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
      const filename = `${timestamp}.patch`;
      writeFileSync(join(patchDir, filename), patchContent, 'utf-8');

      return filename;
    } catch (error) {
      console.error('[ERROR] Failed to save patch file:', error.message);
      return null;
    }
  }

  /**
   * Cleanup snapshot tag and reset state
   */
  clear() {
    if (this.snapshotTag) {
      spawnSync('git', ['tag', '-d', this.snapshotTag], {
        cwd: this.cwd,
        stdio: 'ignore',
      });
      this.snapshotTag = null;
    }
  }
}

export default PatchStorage;
