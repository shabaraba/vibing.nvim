/**
 * Shared build-fingerprint logic for the vibing-nvim MCP server launcher.
 *
 * Used by both run.mjs (to decide whether a self-build is needed) and
 * write-fingerprint.mjs (invoked by build.sh right after its own build, so
 * that run.mjs sees that build as fresh instead of re-running `npm ci` over
 * the node_modules symlink build.sh sets up in the plugin cache).
 */
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { createHash } from 'node:crypto';

const IGNORED_FILE_PATTERN = /(?:^\.DS_Store$|\.sw[op]$|~$|\.tmp$)/;

function listFilesRecursive(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    if (IGNORED_FILE_PATTERN.test(entry.name)) return [];
    const full = join(dir, entry.name);
    return entry.isDirectory() ? listFilesRecursive(full) : [full];
  });
}

export function computeFingerprint(mcpDir) {
  const hash = createHash('sha256');
  const inputs = ['package.json', 'package-lock.json', 'tsconfig.json']
    .map((f) => join(mcpDir, f))
    .filter(existsSync)
    .concat(listFilesRecursive(join(mcpDir, 'src')).sort());
  for (const file of inputs) {
    hash.update(relative(mcpDir, file));
    hash.update(readFileSync(file));
  }
  return hash.digest('hex');
}

export function fingerprintFilePath(mcpDir) {
  return join(mcpDir, 'dist', '.build-fingerprint');
}
