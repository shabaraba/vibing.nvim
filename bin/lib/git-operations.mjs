/**
 * Low-level Git operations wrapper.
 * Encapsulates git command execution with consistent error handling.
 */

import { spawnSync } from 'child_process';
import { existsSync } from 'fs';
import { join } from 'path';

class GitOperations {
  constructor(cwd, options = {}) {
    this.cwd = cwd;
    this.defaultTimeout = options.timeout || 30000; // 30 seconds default
  }

  /**
   * Execute git command with consistent error handling.
   * @param {string[]} args - Git command arguments
   * @param {Object} options - Additional spawn options
   * @returns {Object} { success: boolean, stdout: string, stderr: string, timedOut: boolean }
   */
  execute(args, options = {}) {
    const result = spawnSync('git', args, {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: options.timeout !== undefined ? options.timeout : this.defaultTimeout,
      ...options,
    });

    const timedOut = result.error?.code === 'ETIMEDOUT';
    if (timedOut) {
      console.error(
        `[ERROR] Git command timed out after ${this.defaultTimeout}ms:`,
        args.join(' ')
      );
    }

    return {
      success: result.error == null && result.status === 0,
      stdout: result.stdout || '',
      stderr: result.stderr || '',
      error: result.error,
      timedOut,
    };
  }

  /**
   * Save current staging state to restore later.
   * @returns {string} Staged diff content
   */
  saveStagingState() {
    const result = this.execute(['diff', '--cached']);
    return result.success ? result.stdout : '';
  }

  /**
   * Restore staging state from saved diff.
   * @param {string} stagedDiff - Saved staging state
   * @returns {boolean} Success status
   */
  restoreStagingState(stagedDiff) {
    if (!stagedDiff || !stagedDiff.trim()) {
      return true;
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

  /**
   * Check if repository is in merge/rebase state.
   * @returns {boolean} True if in merge/rebase
   */
  isInMergeOrRebase() {
    return existsSync(join(this.cwd, '.git', 'MERGE_HEAD'));
  }

  /**
   * Check if tag exists.
   * @param {string} tagName - Tag name to check
   * @returns {boolean} True if tag exists
   */
  tagExists(tagName) {
    const result = this.execute(['tag', '-l', tagName]);
    return result.success && result.stdout.trim() !== '';
  }

  /**
   * Stage all files (including untracked).
   * @returns {Object} Result with success status
   */
  stageAll() {
    const result = this.execute(['add', '-A']);
    if (!result.success) {
      console.error('[ERROR] Failed to stage files:', result.error?.message || result.stderr);
    }
    return result;
  }

  /**
   * Create a commit.
   * @param {string} message - Commit message
   * @param {Object} options - Commit options
   * @returns {Object} Result with success status
   */
  commit(message, options = {}) {
    const args = ['commit', '--quiet'];
    if (options.allowEmpty) args.push('--allow-empty');
    if (options.noVerify) args.push('--no-verify');
    args.push('-m', message);

    const result = this.execute(args);
    if (!result.success) {
      console.error('[ERROR] Failed to create commit:', result.error?.message || result.stderr);
    }
    return result;
  }

  /**
   * Create a tag.
   * @param {string} tagName - Tag name
   * @returns {Object} Result with success status
   */
  createTag(tagName) {
    const result = this.execute(['tag', tagName]);
    if (!result.success) {
      console.error('[ERROR] Failed to create tag:', result.error?.message || result.stderr);
    }
    return result;
  }

  /**
   * Delete a tag.
   * @param {string} tagName - Tag name
   * @returns {Object} Result with success status
   */
  deleteTag(tagName) {
    return this.execute(['tag', '-d', tagName], {
      stdio: ['ignore', 'ignore', 'ignore'],
    });
  }

  /**
   * Reset to a specific state.
   * @param {string} mode - Reset mode ('soft', 'hard', 'mixed')
   * @param {string} target - Reset target (e.g., 'HEAD~1')
   * @returns {Object} Result with success status
   */
  reset(mode, target = 'HEAD') {
    const modeFlags = { soft: '--soft', hard: '--hard', mixed: '--mixed' };
    const args = ['reset', '--quiet'];

    if (modeFlags[mode]) {
      args.push(modeFlags[mode]);
    }
    args.push(target);

    const result = this.execute(args);
    if (!result.success) {
      console.error(`[ERROR] Failed to reset (${mode}):`, result.error?.message || result.stderr);
    }
    return result;
  }

  /**
   * Generate diff between snapshot and current state.
   * @param {string} snapshotTag - Snapshot tag name
   * @returns {Object} Result with success status and diff content
   */
  diffAgainstSnapshot(snapshotTag) {
    const result = this.execute(['diff', '--cached', '--relative', snapshotTag]);
    if (!result.success) {
      console.error('[ERROR] Failed to generate diff:', result.error?.message || result.stderr);
    }
    return result;
  }
}

export default GitOperations;
