/**
 * Patch storage for tracking file modifications during a session
 * Uses file tracking approach: tracks Claude-modified files and generates
 * diffs only for those files (tracked: git diff, untracked: git diff --no-index)
 */

import { writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { spawnSync } from 'child_process';
import { homedir } from 'os';

/**
 * Session state for patch generation
 */
class PatchStorage {
  constructor() {
    this.sessionId = null;
    this.cwd = process.cwd();
    this.saveLocationType = 'project';
    this.saveDir = null;
    this.modifiedFiles = new Set(); // Track Claude-modified files
  }

  /**
   * Set session ID for this patch storage instance
   * @param {string} sessionId - Session ID
   */
  setSessionId(sessionId) {
    this.sessionId = sessionId;
  }

  /**
   * Set current working directory
   * @param {string} cwd - Working directory
   */
  setCwd(cwd) {
    this.cwd = cwd;
  }

  /**
   * Set save location configuration
   * @param {string} saveLocationType - "project" | "user" | "custom"
   * @param {string|null} saveDir - Custom save directory (only used when type is "custom")
   */
  setSaveConfig(saveLocationType, saveDir) {
    this.saveLocationType = saveLocationType || 'project';
    this.saveDir = saveDir;
  }

  /**
   * Take a git snapshot (git add -A) at session start
   * This stages all current changes as the baseline
   */
  takeSnapshot() {
    try {
      spawnSync('git', ['add', '-A'], {
        cwd: this.cwd,
        stdio: 'ignore',
      });
    } catch (error) {
      console.error('[ERROR] Failed to take git snapshot:', error.message);
    }
  }

  /**
   * Track a file that was modified by Claude
   * @param {string} filePath - Absolute or relative file path
   */
  trackFile(filePath) {
    // Store as-is (both absolute and relative paths are supported)
    this.modifiedFiles.add(filePath);
  }

  /**
   * Check if a file is tracked by git
   * @param {string} filePath - Relative file path
   * @returns {boolean} True if file is tracked
   */
  isFileTracked(filePath) {
    try {
      const result = spawnSync('git', ['ls-files', filePath], {
        cwd: this.cwd,
        encoding: 'utf-8',
        stdio: ['ignore', 'pipe', 'pipe'],
      });

      return result.status === 0 && result.stdout && result.stdout.trim() === filePath;
    } catch {
      return false;
    }
  }

  /**
   * Generate diff for a tracked file
   * @param {string} filePath - Relative file path
   * @returns {string|null} Diff content or null
   */
  generateTrackedFileDiff(filePath) {
    try {
      const result = spawnSync('git', ['diff', 'HEAD', '--', filePath], {
        cwd: this.cwd,
        encoding: 'utf-8',
        stdio: ['ignore', 'pipe', 'pipe'],
      });

      if (result.status === 0 && result.stdout && result.stdout.trim()) {
        return result.stdout;
      }
    } catch (error) {
      console.error(`[ERROR] Failed to generate diff for tracked file ${filePath}:`, error.message);
    }

    return null;
  }

  /**
   * Generate diff for an untracked file using git diff --no-index
   * @param {string} filePath - Absolute or relative file path
   * @returns {string|null} Diff content or null
   */
  generateUntrackedFileDiff(filePath) {
    try {
      const result = spawnSync('git', ['diff', '--no-index', '/dev/null', filePath], {
        cwd: this.cwd,
        encoding: 'utf-8',
        stdio: ['ignore', 'pipe', 'pipe'],
      });

      // Exit status 1 is expected when files differ
      if (result.status === 1 && result.stdout && result.stdout.trim()) {
        let patchContent = result.stdout;

        // git diff --no-index /dev/null /path/to/file produces:
        // - For relative paths: diff --git a/path/to/file b/path/to/file
        // - For absolute paths: diff --git a/path/to/file b/path/to/file (without leading /)
        // We need to preserve the original path format in the diff header

        // Extract the path that git generated (without leading /)
        const gitPath = patchContent.match(/diff --git a\/[^/](.+?) b\//)?.[1];
        if (gitPath) {
          // Reconstruct with the original filePath
          const normalizedPath = filePath.startsWith('/') ? filePath.substring(1) : filePath;
          patchContent = patchContent.replace(
            /diff --git a\/[^/](.+?) b\/(.+)/,
            `diff --git a/${normalizedPath} b/${normalizedPath}`
          );
        }

        return patchContent;
      }
    } catch (error) {
      console.error(
        `[ERROR] Failed to generate diff for untracked file ${filePath}:`,
        error.message
      );
    }

    return null;
  }

  /**
   * Generate patch for all tracked files
   * @returns {string|null} Patch content or null if no modifications
   */
  async generateSessionPatch() {
    if (this.modifiedFiles.size === 0) {
      return null;
    }

    let fullPatch = '';

    for (const filePath of this.modifiedFiles) {
      const isTracked = this.isFileTracked(filePath);

      let diff;
      if (isTracked) {
        diff = this.generateTrackedFileDiff(filePath);
      } else {
        diff = this.generateUntrackedFileDiff(filePath);
      }

      if (diff) {
        fullPatch += diff + '\n';
      }
    }

    return fullPatch.trim() || null;
  }

  /**
   * Get list of modified files
   * @returns {string[]} Array of tracked file paths
   */
  getModifiedFiles() {
    return Array.from(this.modifiedFiles);
  }

  /**
   * Get patch base directory based on save location type
   * Matches the logic in lua/vibing/infrastructure/storage/patch_storage.lua:get_patches_base_dir()
   * @returns {string} Base directory for patches
   */
  getPatchesBaseDir() {
    if (this.saveLocationType === 'project') {
      return join(this.cwd, '.vibing', 'patches');
    } else if (this.saveLocationType === 'user') {
      // Equivalent to Neovim's stdpath("data")
      return join(homedir(), '.local', 'share', 'nvim', 'vibing', 'patches');
    } else if (this.saveLocationType === 'custom') {
      let basePath = this.saveDir || join(this.cwd, '.vibing');
      // Remove trailing /chats or /chat if present
      basePath = basePath.replace(/\/chats?\/?$/, '');
      return join(basePath, 'patches');
    } else {
      // Default to project
      return join(this.cwd, '.vibing', 'patches');
    }
  }

  /**
   * Save patch to file
   * @param {string} patchContent - Patch content
   * @returns {string|null} Patch filename or null on error
   */
  savePatchToFile(patchContent) {
    if (!patchContent || !this.sessionId) {
      return null;
    }

    try {
      // Get base directory based on configuration
      const patchBaseDir = this.getPatchesBaseDir();
      const patchDir = join(patchBaseDir, this.sessionId);

      // Create directory if not exists
      mkdirSync(patchDir, { recursive: true });

      // Generate filename (without session ID prefix since it's in directory name)
      const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
      const filename = `${timestamp}.patch`;
      const filepath = join(patchDir, filename);

      // Write patch file
      writeFileSync(filepath, patchContent, 'utf-8');

      return filename;
    } catch (error) {
      console.error('[ERROR] Failed to save patch file:', error.message);
      return null;
    }
  }

  /**
   * Clear session state
   */
  clear() {
    this.modifiedFiles.clear();
  }
}

export default PatchStorage;
