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
import { existsSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { spawnSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { computeFingerprint, fingerprintFilePath } from './build-fingerprint.mjs';

const mcpDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const distEntry = join(mcpDir, 'dist', 'index.js');
const nodeModulesDir = join(mcpDir, 'node_modules');
const fingerprintFile = fingerprintFilePath(mcpDir);

// Claude Code gives a plugin's MCP server 30s to come up, and this launcher
// spends that budget before the server is even spawned. `npm ci` defaults to an
// audit request and a funding request against the registry, and revalidates
// package metadata it already has cached — so how long it takes depends on the
// registry rather than on this machine. Measured against the same warm cache on
// macOS, plain `npm ci` ran 31.1s once and ~1.5s hours later; these flags held
// it at ~1.3s throughout. The point is not the average, it is that without them
// the step can exceed the deadline at a moment nothing here controls, and the
// whole vibing-nvim tool set then silently disappears from the session.
// (A genuinely cold cache still fetches tarballs and still takes minutes; only
// `./build.sh`, which is under no such deadline, can fix that case.)
const OFFLINE_FIRST_FLAGS = ['--prefer-offline', '--no-audit', '--no-fund'];

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

const fingerprint = computeFingerprint(mcpDir);
if (isBuildStale(fingerprint)) {
  console.error('[vibing-nvim] Building MCP server...');
  // Drop any existing fingerprint up front so a build that fails partway
  // (tsc can emit partial output despite reporting errors) never leaves a
  // stale fingerprint behind that would make a later, unrelated source
  // state look "already built" against a corrupted dist/.
  rmSync(fingerprintFile, { force: true });
  run('npm', ['ci', ...OFFLINE_FIRST_FLAGS, '--silent']);
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
