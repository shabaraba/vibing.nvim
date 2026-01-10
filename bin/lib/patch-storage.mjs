/**
 * Patch storage for tracking file modifications during a session
 * Implements ADR 006: JavaScript-based Patch Storage Implementation
 */

import { readFileSync, existsSync, writeFileSync, mkdirSync, realpathSync } from 'fs';
import { resolve, join } from 'path';
import { spawnSync } from 'child_process';
import { homedir } from 'os';

/**
 * Session state for tracking modified files
 */
class PatchStorage {
  constructor() {
    this.currentSessionModifiedFiles = new Set();
    this.savedFileContents = new Map();
    this.sessionId = null;
    this.cwd = process.cwd();
    this.saveLocationType = 'project';
    this.saveDir = null;
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
   * Read file content if exists, null otherwise
   * @param {string} filePath - File path
   * @returns {string|null} File content or null
   */
  readFileIfExists(filePath) {
    try {
      const normalizedPath = resolve(this.cwd, filePath);
      if (existsSync(normalizedPath)) {
        // Resolve symlinks and relative paths to canonical path
        const realPath = realpathSync(normalizedPath);
        return readFileSync(realPath, 'utf-8');
      }
      return null;
    } catch {
      return null;
    }
  }

  /**
   * Check if file is tracked by git
   * @param {string} filePath - File path
   * @returns {boolean} True if tracked
   */
  isGitTracked(filePath) {
    try {
      const normalizedPath = resolve(this.cwd, filePath);
      const result = spawnSync('git', ['ls-files', '--error-unmatch', normalizedPath], {
        stdio: 'ignore',
        cwd: this.cwd,
      });
      return result.status === 0;
    } catch {
      return false;
    }
  }

  /**
   * Track Edit/Write tool usage
   * @param {string} filePath - File path being modified
   */
  trackEditWrite(filePath) {
    if (!filePath) return;

    // Save original content on first modification
    if (!this.savedFileContents.has(filePath)) {
      const content = this.readFileIfExists(filePath);
      this.savedFileContents.set(filePath, content);
    }

    this.currentSessionModifiedFiles.add(filePath);
  }

  /**
   * Track nvim_set_buffer tool usage from tool_result
   * @param {string} resultText - Tool result text
   */
  trackNvimSetBuffer(resultText) {
    if (!resultText) return;

    const match = resultText.match(/Buffer updated successfully \(([^)]+)\)/);
    if (match) {
      const filePath = match[1];

      if (!this.savedFileContents.has(filePath)) {
        const content = this.readFileIfExists(filePath);
        this.savedFileContents.set(filePath, content);
      }

      this.currentSessionModifiedFiles.add(filePath);
    }
  }

  /**
   * Generate unified diff for a file
   * @param {string} oldContent - Original content
   * @param {string} newContent - Modified content
   * @param {string} filePath - File path
   * @returns {string|null} Unified diff or null if no changes
   */
  generateUnifiedDiff(oldContent, newContent, filePath) {
    if (oldContent === newContent) {
      return null;
    }

    // Normalize line endings (CRLF -> LF) before splitting
    const normalizeLineEndings = (text) => (text || '').replace(/\r\n/g, '\n');
    const oldLines = normalizeLineEndings(oldContent).split('\n');
    const newLines = normalizeLineEndings(newContent).split('\n');

    const header = [
      `diff --git a/${filePath} b/${filePath}`,
      `--- a/${filePath}`,
      `+++ b/${filePath}`,
      `@@ -1,${oldLines.length} +1,${newLines.length} @@`,
    ];

    const body = [];
    const maxLines = Math.max(oldLines.length, newLines.length);

    for (let i = 0; i < maxLines; i++) {
      const oldLine = oldLines[i];
      const newLine = newLines[i];

      if (oldLine === newLine && oldLine !== undefined) {
        body.push(' ' + oldLine);
      } else {
        if (oldLine !== undefined) {
          body.push('-' + oldLine);
        }
        if (newLine !== undefined) {
          body.push('+' + newLine);
        }
      }
    }

    return [...header, ...body].join('\n');
  }

  /**
   * Generate diff for a new file
   * @param {string} filePath - File path
   * @param {string} content - File content
   * @returns {string} Unified diff for new file
   */
  generateNewFileDiff(filePath, content) {
    const lines = content.split('\n');
    const header = [
      `diff --git a/${filePath} b/${filePath}`,
      'new file mode 100644',
      '--- /dev/null',
      `+++ b/${filePath}`,
      `@@ -0,0 +1,${lines.length} @@`,
    ];

    const body = lines.map((line) => '+' + line);

    return [...header, ...body].join('\n');
  }

  /**
   * Generate patch for all modified files in this session
   * @returns {string|null} Patch content or null if no modifications
   */
  async generateSessionPatch() {
    if (this.currentSessionModifiedFiles.size === 0) {
      return null;
    }

    const patches = [];

    for (const file of this.currentSessionModifiedFiles) {
      const normalizedPath = resolve(this.cwd, file);
      const currentContent = this.readFileIfExists(file);
      const savedContent = this.savedFileContents.get(file);

      if (savedContent != null) {
        // Modified file: generate diff
        const diff = this.generateUnifiedDiff(savedContent, currentContent || '', file);
        if (diff) {
          patches.push(diff);
        }
      } else {
        // New file
        if (currentContent && !this.isGitTracked(normalizedPath)) {
          // Untracked file: output as new file
          const diff = this.generateNewFileDiff(file, currentContent);
          patches.push(diff);
        }
      }
    }

    if (patches.length === 0) {
      return null;
    }

    return patches.join('\n\n');
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
    this.currentSessionModifiedFiles.clear();
    this.savedFileContents.clear();
  }
}

export default PatchStorage;
