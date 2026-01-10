/**
 * Tracks Claude-modified files and generates unified diffs for a session.
 * Flow: takeSnapshot() at start -> trackFile() during tool use -> generatePatch() at end
 */

import { writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { spawnSync } from 'child_process';
import { homedir } from 'os';

class PatchStorage {
  constructor() {
    this.sessionId = null;
    this.cwd = process.cwd();
    this.saveLocationType = 'project';
    this.saveDir = null;
    this.modifiedFiles = new Set();
  }

  setSessionId(sessionId) {
    this.sessionId = sessionId;
  }

  setCwd(cwd) {
    this.cwd = cwd;
  }

  setSaveConfig(saveLocationType, saveDir) {
    this.saveLocationType = saveLocationType || 'project';
    this.saveDir = saveDir;
  }

  takeSnapshot() {
    const result = spawnSync('git', ['add', '-A'], { cwd: this.cwd, stdio: 'ignore' });
    if (result.error) {
      console.error('[ERROR] Failed to take git snapshot:', result.error.message);
    }
  }

  trackFile(filePath) {
    this.modifiedFiles.add(filePath);
  }

  isGitTracked(filePath) {
    const result = spawnSync('git', ['ls-files', filePath], {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    // git ls-files returns output if file is tracked (empty if not)
    return result.status === 0 && result.stdout?.trim().length > 0;
  }

  generateDiffForTrackedFile(filePath) {
    const result = spawnSync('git', ['diff', 'HEAD', '--', filePath], {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });

    const output = result.stdout?.trim();
    return result.status === 0 && output ? result.stdout : null;
  }

  generateDiffForNewFile(filePath) {
    const result = spawnSync('git', ['diff', '--no-index', '/dev/null', filePath], {
      cwd: this.cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });

    if (result.status !== 1 || !result.stdout?.trim()) {
      return null;
    }

    return result.stdout;
  }

  generatePatch() {
    if (this.modifiedFiles.size === 0) {
      return null;
    }

    const diffs = [];
    for (const filePath of this.modifiedFiles) {
      const diff = this.isGitTracked(filePath)
        ? this.generateDiffForTrackedFile(filePath)
        : this.generateDiffForNewFile(filePath);

      if (diff) {
        diffs.push(diff);
      }
    }

    return diffs.length > 0 ? diffs.join('\n').trim() : null;
  }

  getModifiedFiles() {
    return Array.from(this.modifiedFiles);
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

  clear() {
    this.modifiedFiles.clear();
  }
}

export default PatchStorage;
