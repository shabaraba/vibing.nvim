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
   * Create snapshot commit with current state (including unstaged/untracked).
   * This becomes the baseline for comparison at session end.
   */
  takeSnapshot() {
    if (!this.sessionId) {
      console.error('[ERROR] Cannot take snapshot: sessionId not set');
      return false;
    }

    const stagedDiff = this.saveStagingState();

    if (existsSync(join(this.cwd, '.git', 'MERGE_HEAD'))) {
      console.error('[ERROR] Cannot take snapshot during merge/rebase');
      return false;
    }

    // Check for existing snapshot tag collision
    const tagCheckResult = spawnSync('git', ['tag', '-l', this.snapshotTag], {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (tagCheckResult.stdout?.trim()) {
      console.error('[ERROR] Snapshot tag already exists:', this.snapshotTag);
      return false;
    }

    const addResult = spawnSync('git', ['add', '-A'], {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (addResult.error || addResult.status !== 0) {
      console.error('[ERROR] Failed to stage files:', addResult.error?.message || addResult.stderr);
      this.restoreStagingState(stagedDiff);
      return false;
    }

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
      { cwd: this.cwd, encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] }
    );
    if (commitResult.error || commitResult.status !== 0) {
      console.error(
        '[ERROR] Failed to create snapshot commit:',
        commitResult.error?.message || commitResult.stderr
      );
      this.restoreStagingState(stagedDiff);
      return false;
    }

    const tagResult = spawnSync('git', ['tag', this.snapshotTag], {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (tagResult.error || tagResult.status !== 0) {
      console.error(
        '[ERROR] Failed to tag snapshot:',
        tagResult.error?.message || tagResult.stderr
      );
      // Attempt to clean up the commit
      spawnSync('git', ['reset', '--hard', 'HEAD~1'], { cwd: this.cwd, stdio: 'ignore' });
      this.restoreStagingState(stagedDiff);
      return false;
    }

    // Reset to original state: remove commit but keep changes
    const softResetResult = spawnSync('git', ['reset', '--soft', 'HEAD~1'], {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (softResetResult.error || softResetResult.status !== 0) {
      console.error(
        '[ERROR] Failed to soft reset:',
        softResetResult.error?.message || softResetResult.stderr
      );
      // Tag still exists for recovery, but working tree may be inconsistent
    }

    const headResetResult = spawnSync('git', ['reset', 'HEAD', '--quiet'], {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (headResetResult.error || headResetResult.status !== 0) {
      console.error(
        '[ERROR] Failed to reset HEAD:',
        headResetResult.error?.message || headResetResult.stderr
      );
    }

    this.restoreStagingState(stagedDiff);
    return true;
  }

  /**
   * Generate patch by comparing current state with snapshot.
   */
  generatePatch() {
    if (!this.snapshotTag) {
      console.error('[ERROR] Cannot generate patch: no snapshot tag');
      return null;
    }

    const stagedDiff = this.saveStagingState();

    const addResult = spawnSync('git', ['add', '-A'], {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (addResult.error || addResult.status !== 0) {
      console.error(
        '[ERROR] Failed to stage files for patch:',
        addResult.error?.message || addResult.stderr
      );
      this.restoreStagingState(stagedDiff);
      return null;
    }

    const diffResult = spawnSync('git', ['diff', '--cached', '--relative', this.snapshotTag], {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (diffResult.error || diffResult.status !== 0) {
      console.error(
        '[ERROR] Failed to generate diff:',
        diffResult.error?.message || diffResult.stderr
      );
      spawnSync('git', ['reset', 'HEAD', '--quiet'], { cwd: this.cwd, stdio: 'ignore' });
      this.restoreStagingState(stagedDiff);
      return null;
    }

    const patchContent = diffResult.stdout?.trim() || null;

    const resetResult = spawnSync('git', ['reset', 'HEAD', '--quiet'], {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (resetResult.error || resetResult.status !== 0) {
      console.error(
        '[ERROR] Failed to reset after diff:',
        resetResult.error?.message || resetResult.stderr
      );
    }

    this.restoreStagingState(stagedDiff);

    return patchContent;
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
      // Ensure patch ends with newline (required by git apply)
      const patchWithNewline = patchContent.endsWith('\n') ? patchContent : patchContent + '\n';
      writeFileSync(join(patchDir, filename), patchWithNewline, 'utf-8');

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
