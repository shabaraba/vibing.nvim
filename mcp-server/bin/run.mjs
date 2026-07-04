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
 *
 * This runs `npm ci`/`npm run build` against whatever is checked out at
 * CLAUDE_PLUGIN_ROOT — only add this plugin's marketplace from a source you
 * trust (see the "Trust note" in mcp-server/README.md).
 */
import { existsSync, readFileSync, writeFileSync, readdirSync, rmSync } from 'node:fs';
import { spawnSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';
import { createHash } from 'node:crypto';

const mcpDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const distEntry = join(mcpDir, 'dist', 'index.js');
const nodeModulesDir = join(mcpDir, 'node_modules');
const fingerprintFile = join(mcpDir, 'dist', '.build-fingerprint');

const IGNORED_FILE_PATTERN = /(?:^\.DS_Store$|\.sw[op]$|~$|\.tmp$)/;

function listFilesRecursive(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    if (IGNORED_FILE_PATTERN.test(entry.name)) return [];
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

function isBuildStale(fingerprint) {
  if (!existsSync(distEntry) || !existsSync(nodeModulesDir) || !existsSync(fingerprintFile)) {
    return true;
  }
  return readFileSync(fingerprintFile, 'utf8').trim() !== fingerprint;
}

function run(command, args) {
  const result = spawnSync(command, args, { cwd: mcpDir, stdio: 'inherit' });
  const label = `${command} ${args.join(' ')}`;
  if (result.error) {
    console.error(`[vibing-nvim] Failed to run: ${label}`);
    throw result.error;
  }
  if (result.status !== 0) {
    console.error(`[vibing-nvim] Command failed (exit ${result.status}): ${label}`);
    process.exit(result.status ?? 1);
  }
}

const fingerprint = computeFingerprint();
if (isBuildStale(fingerprint)) {
  console.error('[vibing-nvim] Building MCP server...');
  // Drop any existing fingerprint up front so a build that fails partway
  // (tsc can emit partial output despite reporting errors) never leaves a
  // stale fingerprint behind that would make a later, unrelated source
  // state look "already built" against a corrupted dist/.
  rmSync(fingerprintFile, { force: true });
  run('npm', ['ci', '--silent']);
  run('npm', ['run', 'build', '--silent']);
  writeFileSync(fingerprintFile, fingerprint);
}

const child = spawn(process.execPath, [distEntry], { stdio: 'inherit', env: process.env });

// Forward termination signals so Claude Code stopping this wrapper also stops
// the actual server process instead of orphaning it.
const forwardSignal = (signal) => child.kill(signal);
const forwardedSignals = ['SIGTERM', 'SIGINT'];
for (const signal of forwardedSignals) {
  process.on(signal, forwardSignal);
}

child.on('exit', (code, signal) => {
  if (signal) {
    for (const s of forwardedSignals) {
      process.removeListener(s, forwardSignal);
    }
    process.kill(process.pid, signal);
  } else {
    process.exit(code ?? 0);
  }
});
