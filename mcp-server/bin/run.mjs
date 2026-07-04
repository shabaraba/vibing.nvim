#!/usr/bin/env node
/**
 * Self-building launcher for the vibing-nvim MCP server.
 *
 * Claude Code plugin installation does not run an install/build step, so
 * this wrapper builds mcp-server/dist on first launch before exec'ing the
 * compiled server. Used as the `command` for the plugin's bundled MCP
 * server in .claude-plugin/plugin.json.
 *
 * For "directory"-source plugin installs, CLAUDE_PLUGIN_ROOT points at the
 * live checkout rather than a per-version cache, so a source update (e.g. a
 * `git pull` outside of build.sh) can leave a stale dist/ behind. A content
 * fingerprint of package.json/package-lock.json/src/ (not just dist/index.js
 * presence) is used to detect that and rebuild.
 */
import { existsSync, readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { spawnSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';
import { createHash } from 'node:crypto';

const mcpDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const distEntry = join(mcpDir, 'dist', 'index.js');
const nodeModulesDir = join(mcpDir, 'node_modules');
const fingerprintFile = join(mcpDir, 'dist', '.build-fingerprint');

function listFilesRecursive(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = join(dir, entry.name);
    return entry.isDirectory() ? listFilesRecursive(full) : [full];
  });
}

function computeFingerprint() {
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

function isBuildStale() {
  if (!existsSync(distEntry) || !existsSync(nodeModulesDir) || !existsSync(fingerprintFile)) {
    return true;
  }
  return readFileSync(fingerprintFile, 'utf8').trim() !== computeFingerprint();
}

function run(command, args) {
  const result = spawnSync(command, args, { cwd: mcpDir, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}

if (isBuildStale()) {
  console.error('[vibing-nvim] Building MCP server...');
  run('npm', ['ci', '--silent']);
  run('npm', ['run', 'build', '--silent']);
  writeFileSync(fingerprintFile, computeFingerprint());
}

const child = spawn(process.execPath, [distEntry], { stdio: 'inherit', env: process.env });
child.on('exit', (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 0);
});
