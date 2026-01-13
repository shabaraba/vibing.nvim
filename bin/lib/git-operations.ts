/**
 * Low-level Git operations wrapper.
 * Encapsulates git command execution with consistent error handling.
 */

import { spawnSync, SpawnSyncOptions } from 'child_process';
import { existsSync } from 'fs';
import { join } from 'path';

interface GitResult {
  success: boolean;
  stdout: string;
  stderr: string;
  error?: Error;
  timedOut: boolean;
}

interface GitCommitOptions {
  allowEmpty?: boolean;
  noVerify?: boolean;
}

interface GitOpsOptions {
  timeout?: number;
}

class GitOperations {
  private cwd: string;
  private defaultTimeout: number;

  constructor(cwd: string, options: GitOpsOptions = {}) {
    this.cwd = cwd;
    this.defaultTimeout = options.timeout || 30000; // 30 seconds default
  }

  /**
   * Execute git command with consistent error handling.
   */
  execute(args: string[], options: SpawnSyncOptions = {}): GitResult {
    const result = spawnSync('git', args, {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: options.timeout !== undefined ? (options.timeout as number) : this.defaultTimeout,
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
   */
  saveStagingState(): string {
    const result = this.execute(['diff', '--cached']);
    return result.success ? result.stdout : '';
  }

  /**
   * Restore staging state from saved diff.
   */
  restoreStagingState(stagedDiff: string): boolean {
    if (!stagedDiff || !stagedDiff.trim()) {
      return true;
    }

    // Validate that diff contains valid patch markers
    // Valid diffs must have either "diff --git" or "@@" hunk markers
    const hasDiffMarkers = /^(diff --git|@@)/m.test(stagedDiff);
    if (!hasDiffMarkers) {
      // No valid patch content, nothing to restore
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
   */
  isInMergeOrRebase(): boolean {
    return existsSync(join(this.cwd, '.git', 'MERGE_HEAD'));
  }

  /**
   * Check if tag exists.
   */
  tagExists(tagName: string): boolean {
    const result = this.execute(['tag', '-l', tagName]);
    return result.success && result.stdout.trim() !== '';
  }

  /**
   * Stage all files (including untracked).
   */
  stageAll(): GitResult {
    const result = this.execute(['add', '-A']);
    if (!result.success) {
      console.error('[ERROR] Failed to stage files:', result.error?.message || result.stderr);
    }
    return result;
  }

  /**
   * Create a commit.
   */
  commit(message: string, options: GitCommitOptions = {}): GitResult {
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
   */
  createTag(tagName: string): GitResult {
    const result = this.execute(['tag', tagName]);
    if (!result.success) {
      console.error('[ERROR] Failed to create tag:', result.error?.message || result.stderr);
    }
    return result;
  }

  /**
   * Delete a tag.
   */
  deleteTag(tagName: string): GitResult {
    return this.execute(['tag', '-d', tagName], {
      stdio: ['ignore', 'ignore', 'ignore'],
    });
  }

  /**
   * Reset to a specific state.
   */
  reset(mode: 'soft' | 'hard' | 'mixed', target: string = 'HEAD'): GitResult {
    const modeFlags: Record<string, string> = { soft: '--soft', hard: '--hard', mixed: '--mixed' };
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
   */
  diffAgainstSnapshot(snapshotTag: string): GitResult {
    const result = this.execute(['diff', '--cached', '--relative', snapshotTag]);
    if (!result.success) {
      console.error('[ERROR] Failed to generate diff:', result.error?.message || result.stderr);
    }
    return result;
  }

  /**
   * Detect if current directory is in a git worktree.
   * @returns { isWorktree: boolean, worktreeName: string | null }
   */
  detectWorktree(): { isWorktree: boolean; worktreeName: string | null } {
    try {
      // Get git common dir (points to main worktree's .git)
      const gitCommonDirResult = this.execute(['rev-parse', '--git-common-dir']);
      if (!gitCommonDirResult.success) {
        return { isWorktree: false, worktreeName: null };
      }
      const gitCommonDir = gitCommonDirResult.stdout.trim();

      // Get git dir (current worktree's .git)
      const gitDirResult = this.execute(['rev-parse', '--git-dir']);
      if (!gitDirResult.success) {
        return { isWorktree: false, worktreeName: null };
      }
      const gitDir = gitDirResult.stdout.trim();

      // If they differ, we're in a worktree
      if (gitCommonDir !== gitDir) {
        // Extract worktree name from path
        const worktreePathResult = this.execute(['rev-parse', '--show-toplevel']);
        if (!worktreePathResult.success) {
          return { isWorktree: true, worktreeName: 'unknown' };
        }

        const worktreePath = worktreePathResult.stdout.trim();
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
}

export default GitOperations;
