/**
 * Snapshot-based patch generation for Claude sessions.
 * Flow: takeSnapshot() creates git commit -> Claude works -> generatePatch() compares current state
 */

import { writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import GitOperations from './git-operations.js';
import { toError } from './utils.js';

class PatchStorage {
  private sessionId: string | null = null;
  private cwd: string;
  private saveLocationType: 'project' | 'user' | 'custom' = 'project';
  private saveDir: string | null = null;
  private snapshotTag: string | null = null;
  private gitOps: GitOperations;

  constructor() {
    this.cwd = process.cwd();
    this.gitOps = new GitOperations(this.cwd, { timeout: 30000 });
  }

  setSessionId(sessionId: string): void {
    this.sessionId = sessionId;

    // Detect worktree environment
    const worktreeInfo = this.gitOps.detectWorktree();

    // Generate worktree-specific tag name
    const worktreeId = worktreeInfo.isWorktree ? `wt-${worktreeInfo.worktreeName}` : 'main';

    // New format: vibing-patch-<worktree-id>-<session-id>
    this.snapshotTag = `vibing-patch-${worktreeId}-${sessionId}`;
  }

  setCwd(cwd: string): void {
    this.cwd = cwd;
    this.gitOps = new GitOperations(cwd, { timeout: 30000 });
  }

  setSaveConfig(saveLocationType: 'project' | 'user' | 'custom', saveDir: string | null): void {
    this.saveLocationType = saveLocationType || 'project';
    this.saveDir = saveDir;
  }

  /**
   * Create snapshot commit with current state (including unstaged/untracked).
   * This becomes the baseline for comparison at session end.
   */
  takeSnapshot(): boolean {
    if (!this.sessionId) {
      console.error('[ERROR] Cannot take snapshot: session ID not set');
      return false;
    }

    const stagedDiff = this.gitOps.saveStagingState();

    if (this.gitOps.isInMergeOrRebase()) {
      console.error('[ERROR] Cannot take snapshot: repository is in merge/rebase state');
      return false;
    }

    if (this.gitOps.tagExists(this.snapshotTag!)) {
      console.error('[ERROR] Cannot take snapshot: tag already exists -', this.snapshotTag);
      return false;
    }

    if (!this.gitOps.stageAll().success) {
      this.gitOps.restoreStagingState(stagedDiff);
      return false;
    }

    if (
      !this.gitOps.commit(`CLAUDE_SESSION_SNAPSHOT_${this.sessionId}`, {
        allowEmpty: true,
        noVerify: true,
      }).success
    ) {
      this.gitOps.restoreStagingState(stagedDiff);
      return false;
    }

    if (!this.gitOps.createTag(this.snapshotTag!).success) {
      this.gitOps.reset('hard', 'HEAD~1');
      this.gitOps.restoreStagingState(stagedDiff);
      return false;
    }

    // Remove commit but keep working tree unchanged (mixed reset = soft + unstage)
    this.gitOps.reset('mixed', 'HEAD~1');
    this.gitOps.restoreStagingState(stagedDiff);

    return true;
  }

  /**
   * Generate patch by comparing current state with snapshot.
   */
  generatePatch(): string | null {
    if (!this.snapshotTag) {
      console.error('[ERROR] Cannot generate patch: no snapshot tag');
      return null;
    }

    const stagedDiff = this.gitOps.saveStagingState();

    if (!this.gitOps.stageAll().success) {
      this.gitOps.restoreStagingState(stagedDiff);
      return null;
    }

    const diffResult = this.gitOps.diffAgainstSnapshot(this.snapshotTag);
    if (!diffResult.success) {
      this.gitOps.reset('mixed', 'HEAD');
      this.gitOps.restoreStagingState(stagedDiff);
      return null;
    }

    const patchContent = diffResult.stdout.trim() || null;

    this.gitOps.reset('mixed', 'HEAD');
    this.gitOps.restoreStagingState(stagedDiff);

    return patchContent;
  }

  getPatchesBaseDir(): string {
    switch (this.saveLocationType) {
      case 'user':
        return join(homedir(), '.local', 'share', 'nvim', 'vibing', 'patches');
      case 'custom': {
        // Remove trailing /chat or /chats suffix to place patches alongside chat dir
        const basePath = (this.saveDir || join(this.cwd, '.vibing')).replace(/\/chats?\/?$/, '');
        return join(basePath, 'patches');
      }
      default:
        return join(this.cwd, '.vibing', 'patches');
    }
  }

  savePatchToFile(patchContent: string): string | null {
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
      const err = toError(error);
      console.error('[ERROR] Failed to save patch file:', err.message);
      return null;
    }
  }

  /**
   * Cleanup snapshot tag and reset state
   */
  clear(): void {
    if (this.snapshotTag) {
      this.gitOps.deleteTag(this.snapshotTag);
      this.snapshotTag = null;
    }
  }
}

export default PatchStorage;
