/**
 * The MCP server's self-build, and the rules that let it run *outside* Claude Code's 30s MCP
 * startup deadline instead of inside it.
 *
 * Imported by run.mjs for the one case that has no alternative (nothing runnable in `dist/`), and
 * run as a detached script for every other case, where the previous build is launched first and
 * this catches up in the background. Which case is which is decided in run.mjs.
 *
 * Two properties make the background form safe, and both live here:
 *
 * - **`dist/` is replaced, never edited.** The compile writes to `dist.tmp/`, the fingerprint is
 *   stamped there, and only then is the finished tree renamed into place. So `dist/` is always
 *   some complete build -- a killed rebuild leaves the previous one untouched rather than a
 *   half-written one, which is what lets run.mjs launch a stale `dist/` without inspecting it.
 *   It also means the fingerprint file's *presence* answers "was this a finished build?" and its
 *   *contents* answer "of which source?", two questions the old in-place build had to conflate by
 *   deleting the fingerprint before it started.
 * - **One build at a time.** The lock is an `O_EXCL` file whose contents are the holder's pid, so
 *   taking it is a single atomic call; a lock whose pid no longer answers `kill(pid, 0)` is
 *   reclaimed rather than obeyed forever.
 */
import { existsSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { computeFingerprint, fingerprintFilePath } from './build-fingerprint.mjs';
import { notifyNvim } from './notify-nvim.mjs';

// Claude Code gives a plugin's MCP server 30s to come up, and this build used to spend that budget
// before the server was even spawned. `npm ci` defaults to an audit request and a funding request
// against the registry, and revalidates package metadata it already has cached -- so how long it
// takes depends on the registry rather than on this machine. Measured against the same warm cache
// on macOS, plain `npm ci` ran 31.1s once and ~1.5s hours later; these flags held it at ~1.3s
// throughout. They stay now that the usual path is a background rebuild, because the one path that
// still runs under the deadline -- a tree with nothing runnable in `dist/` -- needs every second.
// (A genuinely cold cache still fetches tarballs and still takes minutes; only `./build.sh`, which
// is under no such deadline, can fix that case.)
const OFFLINE_FIRST_FLAGS = ['--prefer-offline', '--no-audit', '--no-fund'];

/**
 * How long the background rebuild waits before touching anything.
 *
 * `npm ci` begins by deleting `node_modules`, and the server it is rebuilding for was spawned out
 * of that very tree moments earlier. Node resolves an ES module graph eagerly at startup and this
 * server imports nothing dynamically, so once it is loaded the directory no longer matters -- but
 * that load takes a few hundred milliseconds and npm's own startup is the same order, so racing it
 * would kill the server this rebuild exists to keep alive. Nothing waits on a detached rebuild, so
 * the margin costs nothing; the environment variable is how the launcher tests skip it.
 */
const STARTUP_GRACE_MS = readIntEnv('VIBING_MCP_REBUILD_GRACE_MS', 5000);

const LOCK_POLL_MS = 100;

/** @param {string} name @param {number} fallback */
function readIntEnv(name, fallback) {
  const value = Number.parseInt(process.env[name] ?? '', 10);
  return Number.isInteger(value) && value >= 0 ? value : fallback;
}

/** @param {string} mcpDir */ const distDirPath = (mcpDir) => join(mcpDir, 'dist');
/** @param {string} mcpDir */ const stagingDirPath = (mcpDir) => join(mcpDir, 'dist.tmp');
/** @param {string} mcpDir */ const lockFilePath = (mcpDir) => join(mcpDir, '.build-lock');

/**
 * Is there something in `dist/` worth launching?
 *
 * All three parts are required and each is missing for a different reason: no `dist/index.js` and
 * there is nothing to run, no `node_modules/` and it cannot resolve its imports, no fingerprint
 * file and the build that produced `dist/` never finished -- so its contents are unknown.
 * @param {string} mcpDir
 * @returns {boolean}
 */
export function hasCompleteBuild(mcpDir) {
  return (
    existsSync(join(distDirPath(mcpDir), 'index.js')) &&
    existsSync(join(mcpDir, 'node_modules')) &&
    existsSync(fingerprintFilePath(mcpDir))
  );
}

/**
 * The source `dist/` was built from, or null when no finished build recorded one.
 * @param {string} mcpDir
 * @returns {string|null}
 */
export function builtFingerprint(mcpDir) {
  try {
    return readFileSync(fingerprintFilePath(mcpDir), 'utf8').trim();
  } catch {
    return null;
  }
}

/**
 * @param {number|null} pid the lock's contents, or null if it was not there to read
 * @returns {boolean} false for a lock with no identifiable owner: it vanished under us, or holds
 *   something this never wrote. Either way there is nobody to wait for.
 */
function isHolderAlive(pid) {
  if (!Number.isInteger(pid)) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM means the pid exists and belongs to another user, which still counts as held.
    return error.code === 'EPERM';
  }
}

/** @param {number} ms */
function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/**
 * Take the build lock, or report that another process holds it.
 * @param {string} mcpDir
 * @param {number} waitMs how long to keep trying before giving up
 * @returns {boolean}
 */
function acquireLock(mcpDir, waitMs) {
  const lockFile = lockFilePath(mcpDir);
  const deadline = Date.now() + waitMs;
  // A lock with no live holder is reclaimed rather than obeyed: a build killed by SIGKILL (the
  // machine sleeping mid-`npm ci`) would otherwise block every later rebuild for good, and the
  // symptom would be the stale server running forever with nothing to explain it. Bounded, because
  // both readings below can be out of date the moment they are taken and a failure with any other
  // cause -- an unwritable directory -- must wait rather than spin.
  let immediateRetries = 2;

  for (;;) {
    try {
      // `wx` is O_CREAT|O_EXCL: the file and its contents appear in one atomic step, so a lock that
      // exists always names its holder.
      writeFileSync(lockFile, String(process.pid), { flag: 'wx' });
      return true;
    } catch {
      // Held, or this directory cannot be written to.
    }

    if (immediateRetries > 0 && !isHolderAlive(readHolder(lockFile))) {
      immediateRetries -= 1;
      // A lock that vanished between the failed create and the read leaves nothing to remove, and
      // `force` is what makes that the same code path as reclaiming a dead holder's.
      rmSync(lockFile, { force: true });
      continue;
    }

    if (Date.now() >= deadline) return false;
    sleepSync(LOCK_POLL_MS);
  }
}

/**
 * @param {string} lockFile
 * @returns {number|null} the pid the lock names, or null if there was nothing to read
 */
function readHolder(lockFile) {
  try {
    return Number.parseInt(readFileSync(lockFile, 'utf8').trim(), 10);
  } catch {
    return null;
  }
}

/**
 * @param {string} mcpDir
 * @param {string[]} args
 * @returns {string|null} null on success, else what failed
 */
function runNpm(mcpDir, args) {
  const result = spawnSync('npm', args, { cwd: mcpDir, stdio: 'inherit' });
  if (result.error) return `could not run \`npm ${args.join(' ')}\`: ${result.error.message}`;
  if (result.status !== 0) return `\`npm ${args.join(' ')}\` exited ${result.status}`;
  return null;
}

/**
 * Move the finished tree over the old one.
 *
 * Two renames rather than a recursive delete and a rename, so the window in which no `dist/`
 * exists is two syscalls wide. A launcher landing inside it finds nothing to run and builds
 * synchronously -- slow, but never wrong.
 * @param {string} mcpDir
 */
function swapIntoPlace(mcpDir) {
  const dist = distDirPath(mcpDir);
  const superseded = `${dist}.superseded`;

  rmSync(superseded, { recursive: true, force: true });
  if (existsSync(dist)) renameSync(dist, superseded);
  renameSync(stagingDirPath(mcpDir), dist);
  rmSync(superseded, { recursive: true, force: true });
}

/**
 * Install, compile into `dist.tmp/`, stamp it, and swap it in.
 *
 * @param {string} mcpDir
 * @param {{ lockWaitMs?: number }} [options]
 * @returns {{ ok: boolean, skipped?: boolean, error?: string }} `skipped` means another process
 *   holds the lock. That is an outcome, not a failure: it is building the same tree, and its
 *   result lands in the same `dist/`.
 */
export function rebuild(mcpDir, { lockWaitMs = 0 } = {}) {
  if (!acquireLock(mcpDir, lockWaitMs)) return { ok: false, skipped: true };

  const staging = stagingDirPath(mcpDir);
  try {
    // Whatever a previous, killed attempt left there says nothing about this source.
    rmSync(staging, { recursive: true, force: true });

    // Read before the install, so that a source edit landing mid-build is recorded as *not* built
    // rather than silently claimed by this one.
    const fingerprint = computeFingerprint(mcpDir);
    const failure =
      runNpm(mcpDir, ['ci', ...OFFLINE_FIRST_FLAGS, '--silent']) ??
      runNpm(mcpDir, ['run', 'build', '--silent', '--', '--outDir', staging]);
    if (failure) return { ok: false, error: failure };

    // Last, and inside the staging tree: this file's existence is the promise that the tree beside
    // it is complete, so it must never be written before the compile that fills it.
    writeFileSync(join(staging, '.build-fingerprint'), fingerprint);
    swapIntoPlace(mcpDir);
    return { ok: true };
  } catch (error) {
    return { ok: false, error: error.message };
  } finally {
    rmSync(lockFilePath(mcpDir), { force: true });
  }
}

// Script mode: the detached background rebuild run.mjs starts when it launches a stale build
// rather than make the session wait for a fresh one. Compared through realpath because the plugin
// directory may be reached through a symlink, in which case the two spellings differ.
const selfPath = fileURLToPath(import.meta.url);
if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(selfPath)) {
  const mcpDir = join(dirname(selfPath), '..');
  if (STARTUP_GRACE_MS > 0) await sleep(STARTUP_GRACE_MS);

  const result = rebuild(mcpDir);
  if (result.ok) {
    notifyNvim('info', 'MCP server rebuilt. The next request uses the new build.');
  } else if (!result.skipped) {
    notifyNvim(
      'error',
      `MCP server rebuild failed (${result.error}). ` +
        'The previous build keeps serving this session; run ./build.sh to fix it.'
    );
  }
}
