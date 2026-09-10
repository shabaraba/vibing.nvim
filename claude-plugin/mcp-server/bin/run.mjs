#!/usr/bin/env node
/**
 * Self-building launcher for the vibing-nvim MCP server.
 *
 * Claude Code plugin installation does not run an install/build step, so this wrapper builds
 * mcp-server/dist before exec'ing the compiled server. Used as the `command` for the plugin's
 * bundled MCP server in .claude-plugin/plugin.json.
 *
 * For "directory"-source plugin installs, CLAUDE_PLUGIN_ROOT points at the live checkout rather
 * than a per-version cache, so a source update (e.g. a `git pull` outside of build.sh) can leave a
 * stale dist/ behind. A content fingerprint of package.json/package-lock.json/src/ (not just
 * dist/index.js presence) is used to detect that.
 *
 * **The build does not get to spend the startup deadline.** Claude Code gives a plugin's MCP
 * server 30s to connect, and overrunning it is invisible: the server never connects, so
 * `mcp__plugin_vibing-nvim_vibing-nvim__*` is absent from the model's tool list for the whole
 * session, while the skills and the `nvim-navigator` agent -- same `--plugin-dir`, no process
 * needed -- load normally. Nothing logs anywhere the user looks (measured; see notify-nvim.mjs),
 * so the model concludes the tools do not exist. A cold `npm ci` takes minutes, which no flag
 * fixes, and the old in-place build never recovered from being killed: it deleted the fingerprint
 * up front, so the next turn started over from the same place and was killed again (#690).
 *
 * So staleness is not what decides whether to build first. Completeness is:
 *
 * - `dist/` is a finished build of this source -> launch it. Nothing to do.
 * - `dist/` is a finished build of *older* source -> launch it anyway, and rebuild detached. The
 *   session runs one turn on the previous server rather than none on a missing one, and the next
 *   launch picks the new build up. rebuild.mjs only ever swaps whole trees into place, which is
 *   what makes an unexamined stale `dist/` safe to run.
 * - `dist/` holds no finished build -> there is nothing to launch, so build now and hope it fits.
 *   Say so first, over RPC, because this is the case that can still end with no tools.
 *
 * This runs `npm ci`/`npm run build` against whatever is checked out at CLAUDE_PLUGIN_ROOT -- only
 * add this plugin's marketplace from a source you trust (see the "Trust note" in
 * mcp-server/README.md).
 */
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { computeFingerprint } from './build-fingerprint.mjs';
import { builtFingerprint, hasCompleteBuild, rebuild } from './rebuild.mjs';
import { notifyNvim } from './notify-nvim.mjs';

const mcpDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const distEntry = join(mcpDir, 'dist', 'index.js');
const rebuildScript = join(mcpDir, 'bin', 'rebuild.mjs');

/**
 * How long the blocking build may wait for a rebuild already in flight.
 *
 * Reached only with nothing to launch, where the alternative to waiting is two `npm ci` runs
 * writing the same `node_modules`. Kept well inside the 30s deadline: the other process finishing
 * hands us a `dist/` for free, and if it does not, spending the remainder on our own build is
 * still better than exiting with none.
 */
const BUILD_LOCK_WAIT_MS = 10_000;

function buildBeforeLaunch() {
  notifyNvim(
    'warn',
    'Building the MCP server, with no previous build to fall back on. Claude Code allows 30s; ' +
      'past that the vibing-nvim tools are missing for this session. Run ./build.sh to build it ' +
      'without a deadline.'
  );
  console.error('[vibing-nvim] Building MCP server...');

  const result = rebuild(mcpDir, { lockWaitMs: BUILD_LOCK_WAIT_MS });
  // A skipped build means another process holds the lock and may have finished in the meantime;
  // only its failure to produce anything runnable is fatal here.
  if (!result.ok && !result.skipped) {
    console.error(`[vibing-nvim] Build failed: ${result.error}`);
    notifyNvim('error', `MCP server build failed (${result.error}). Run ./build.sh.`);
    process.exit(1);
  }
  if (!hasCompleteBuild(mcpDir)) {
    console.error('[vibing-nvim] Build produced no runnable server');
    notifyNvim('error', 'MCP server build produced nothing runnable. Run ./build.sh.');
    process.exit(1);
  }
}

function rebuildInBackground() {
  notifyNvim(
    'info',
    'MCP server source changed since it was built. This session uses the previous build while a ' +
      'new one is built in the background.'
  );
  console.error('[vibing-nvim] Rebuilding MCP server in the background...');

  try {
    spawn(process.execPath, [rebuildScript], {
      cwd: mcpDir,
      detached: true,
      stdio: 'ignore',
      env: process.env,
    }).unref();
  } catch (error) {
    // The launch itself is unaffected: the server about to start is a working one, just older.
    console.error(`[vibing-nvim] Could not start the background rebuild: ${error.message}`);
  }
}

if (!hasCompleteBuild(mcpDir)) {
  buildBeforeLaunch();
} else if (builtFingerprint(mcpDir) !== computeFingerprint(mcpDir)) {
  rebuildInBackground();
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
