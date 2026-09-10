#!/usr/bin/env node
/**
 * claude-plugin/mcp-server/bin/run.mjs runs before the MCP server exists, inside the 30s Claude
 * Code allows a plugin's server to start. Everything it spends there comes out of that budget, and
 * overrunning it is silent: the server never connects, so the whole vibing-nvim tool set vanishes
 * from the session while the skills from the same `--plugin-dir` load normally. Nothing else in the
 * project notices, because the failure is a missing tool rather than a failing command.
 *
 * A plain `npm ci` does not reliably fit in that budget, and a cold one takes minutes, which no
 * flag fixes. So the launcher no longer spends the deadline on a build it can avoid: a `dist/` that
 * is a *finished* build of older source is launched as-is and rebuilt detached, and only a `dist/`
 * with nothing runnable in it is built first (#690).
 *
 * These tests run the real launcher against a throwaway mcp-server tree with a fake `npm` first on
 * PATH, so they assert on what it actually did -- the argv it passed, which build it launched, how
 * long it took to get there -- rather than on the text of the file.
 */

import { strict as assert } from 'assert';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import * as net from 'node:net';
import { setTimeout as sleep } from 'node:timers/promises';
import { mkdtemp, mkdir, copyFile, writeFile, chmod, rm } from 'fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath, pathToFileURL } from 'url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const launcherDir = join(repoRoot, 'claude-plugin/mcp-server/bin');
const LAUNCHER_FILES = ['run.mjs', 'rebuild.mjs', 'build-fingerprint.mjs', 'notify-nvim.mjs'];

/**
 * A stand-in for npm that records its argv and reproduces the two effects the launcher depends on:
 * `ci` creates node_modules, and `run build` writes an entry point to wherever `--outDir` points
 * (the rebuild compiles into a staging directory, not into dist/). `NPM_DELAY` makes it slow, which
 * is how a test tells "the launcher waited for the build" apart from "it did not".
 */
const FAKE_NPM = `#!/bin/sh
printf '%s\\n' "$*" >> "$NPM_LOG"
if [ -n "$NPM_DELAY" ]; then sleep "$NPM_DELAY"; fi
if [ "$1" = "ci" ]; then
  mkdir -p node_modules
fi
if [ "$1" = "run" ]; then
  out=dist
  while [ $# -gt 0 ]; do
    if [ "$1" = "--outDir" ]; then out="$2"; fi
    shift
  done
  mkdir -p "$out"
  echo 'process.exit(0)' > "$out/index.js"
fi
exit 0
`;

/** A dist/index.js that proves which build was launched, by leaving a file behind. */
const markerServer = (path) =>
  `require('fs').writeFileSync(${JSON.stringify(path)}, 'launched');\nprocess.exit(0);\n`;

/** Build a throwaway tree shaped like claude-plugin/mcp-server/, with the real launcher in it. */
async function makeTree() {
  const dir = await mkdtemp(join(tmpdir(), 'vibing-launcher-'));
  await mkdir(join(dir, 'mcp/bin'), { recursive: true });
  await mkdir(join(dir, 'mcp/src'), { recursive: true });
  await mkdir(join(dir, 'fakebin'), { recursive: true });

  for (const file of LAUNCHER_FILES) {
    await copyFile(join(launcherDir, file), join(dir, 'mcp/bin', file));
  }
  await writeFile(join(dir, 'mcp/package.json'), '{ "name": "stub", "version": "0.0.0" }\n');
  await writeFile(join(dir, 'mcp/src/index.ts'), 'export const x = 1;\n');

  const npm = join(dir, 'fakebin/npm');
  await writeFile(npm, FAKE_NPM);
  await chmod(npm, 0o755);

  return dir;
}

/** Run the launcher in `dir`, and return its exit code, elapsed ms, and one entry per npm call. */
function runLauncher(dir, extraEnv = {}) {
  const log = join(dir, 'npm.log');
  const env = {
    ...process.env,
    PATH: `${join(dir, 'fakebin')}:${process.env.PATH}`,
    NPM_LOG: log,
    // The suite may itself be running inside a vibing.nvim session, where this variable names the
    // developer's live Neovim. Left in place, every launcher under test would notify it.
    VIBING_NVIM_RPC_PORT: '',
    // The background rebuild waits for the server it replaces to finish loading node_modules.
    // Nothing is really loading here, and the tests would only wait.
    VIBING_MCP_REBUILD_GRACE_MS: '0',
    ...extraEnv,
  };

  const startedAt = Date.now();
  const result = spawnSync(process.execPath, [join(dir, 'mcp/bin/run.mjs')], {
    env,
    encoding: 'utf8',
    timeout: 60_000,
  });
  const elapsedMs = Date.now() - startedAt;
  assert.notEqual(result.status, null, `launcher did not exit: ${result.error ?? 'unknown'}`);
  return { code: result.status, stderr: result.stderr, elapsedMs, calls: npmCalls(dir) };
}

/** @returns {string[]} one entry per fake-npm invocation so far */
function npmCalls(dir) {
  const log = join(dir, 'npm.log');
  if (!existsSync(log)) return [];
  return readFileSync(log, 'utf8')
    .split('\n')
    .filter((line) => line.length > 0);
}

/** Wait for `predicate`, which the detached rebuild satisfies on its own schedule. */
async function eventually(predicate, what, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (predicate()) return;
    if (Date.now() >= deadline) assert.fail(`timed out waiting for ${what}`);
    await sleep(50);
  }
}

/** Put a tree into the state a successful `./build.sh` leaves: built, current, complete. */
function prime(dir) {
  const primed = runLauncher(dir);
  // A first run that died leaves no dist/ and no fingerprint, so whatever the test does next would
  // be measuring a broken launcher rather than the thing it is about.
  assert.equal(primed.code, 0, `priming run failed: ${primed.stderr}`);
  return primed;
}

test('the self-build keeps npm off the registry', async () => {
  const dir = await makeTree();
  try {
    const { calls } = runLauncher(dir);
    const install = calls.find((call) => call.startsWith('ci '));
    assert.ok(install, `no \`npm ci\` was run; calls were ${JSON.stringify(calls)}`);
    for (const flag of ['--prefer-offline', '--no-audit', '--no-fund']) {
      assert.ok(
        install.includes(flag),
        `\`npm ${install}\` is missing ${flag}; a self-build that talks to the registry ` +
          `overruns Claude Code's 30s MCP startup deadline and the tools never appear`
      );
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('a tree with nothing runnable is built before the server is launched', async () => {
  const dir = await makeTree();
  try {
    const { code, calls, stderr } = runLauncher(dir);
    assert.equal(code, 0, `launcher failed: ${stderr}`);
    assert.equal(calls.length, 2, `expected an install and a build, got ${JSON.stringify(calls)}`);
    assert.ok(calls[1].startsWith('run build'));
    assert.ok(
      existsSync(join(dir, 'mcp/dist/.build-fingerprint')),
      'the finished build left no fingerprint, so the next launch would build it again'
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('a tree already built for this source is launched without touching npm', async () => {
  const dir = await makeTree();
  try {
    prime(dir);
    await rm(join(dir, 'npm.log'));

    const { code, calls } = runLauncher(dir);
    assert.equal(code, 0);
    assert.deepEqual(calls, [], 'an unchanged tree spent a build it did not need');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('a stale build is launched at once and rebuilt in the background', async () => {
  const dir = await makeTree();
  try {
    prime(dir);
    await rm(join(dir, 'npm.log'));

    // The state the incident in #690 started from: source moved, so the recorded fingerprint no
    // longer matches, but the previous build is intact and perfectly runnable.
    const marker = join(dir, 'launched-stale');
    await writeFile(join(dir, 'mcp/dist/index.js'), markerServer(marker));
    await writeFile(join(dir, 'mcp/src/index.ts'), 'export const x = 2;\n');

    // Long enough that a launcher which waited for the build could not possibly come in under the
    // assertion below, and short enough not to dominate the suite.
    const { code, elapsedMs } = runLauncher(dir, { NPM_DELAY: '3' });

    assert.equal(code, 0);
    assert.ok(existsSync(marker), 'the stale build was not launched');
    assert.ok(
      elapsedMs < 2000,
      `the launcher waited ${elapsedMs}ms for the rebuild; the point is that it does not`
    );

    await eventually(
      () => npmCalls(dir).some((call) => call.startsWith('run build')),
      'the detached rebuild to run'
    );

    const { computeFingerprint } = await import(
      pathToFileURL(join(dir, 'mcp/bin/build-fingerprint.mjs')).href
    );
    await eventually(
      () =>
        existsSync(join(dir, 'mcp/dist/.build-fingerprint')) &&
        readFileSync(join(dir, 'mcp/dist/.build-fingerprint'), 'utf8').trim() ===
          computeFingerprint(join(dir, 'mcp')),
      'the rebuilt tree to be swapped into place'
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('a dist left behind by an interrupted build is not launched', async () => {
  const dir = await makeTree();
  try {
    prime(dir);
    await rm(join(dir, 'npm.log'));
    // What a build killed partway leaves: output in dist/, but no fingerprint vouching for it. Its
    // contents are unknown, so launching it would be worse than spending the deadline.
    await rm(join(dir, 'mcp/dist/.build-fingerprint'));
    const marker = join(dir, 'launched-partial');
    await writeFile(join(dir, 'mcp/dist/index.js'), markerServer(marker));

    const { code, calls } = runLauncher(dir);

    assert.equal(code, 0);
    assert.ok(
      calls.some((call) => call.startsWith('ci ')),
      `an unvouched-for dist/ was launched as-is; calls were ${JSON.stringify(calls)}`
    );
    assert.ok(!existsSync(marker), 'the partial build was launched');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('a rebuild already in flight is not started a second time', async () => {
  const dir = await makeTree();
  try {
    prime(dir);
    await rm(join(dir, 'npm.log'));
    await writeFile(join(dir, 'mcp/src/index.ts'), 'export const x = 3;\n');

    // This test process is unquestionably alive, so a lock naming it is a lock that is held.
    await writeFile(join(dir, 'mcp/.build-lock'), String(process.pid));
    const held = runRebuildScript(dir);
    assert.equal(held.status, 0, `rebuild exited ${held.status}: ${held.stderr}`);
    assert.deepEqual(npmCalls(dir), [], 'a second rebuild ran against a tree already being built');

    // A lock left behind by a process that no longer exists must not block rebuilds for good --
    // the symptom would be the stale server running forever with nothing to explain it.
    const dead = spawnSync(process.execPath, ['-e', '']).pid;
    await writeFile(join(dir, 'mcp/.build-lock'), String(dead));
    const reclaimed = runRebuildScript(dir);
    assert.equal(reclaimed.status, 0, `rebuild exited ${reclaimed.status}: ${reclaimed.stderr}`);
    assert.ok(
      npmCalls(dir).some((call) => call.startsWith('ci ')),
      'a lock held by a dead process was obeyed'
    );
    assert.ok(!existsSync(join(dir, 'mcp/.build-lock')), 'the rebuild kept its lock');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

function runRebuildScript(dir) {
  return spawnSync(process.execPath, [join(dir, 'mcp/bin/rebuild.mjs')], {
    env: {
      ...process.env,
      PATH: `${join(dir, 'fakebin')}:${process.env.PATH}`,
      NPM_LOG: join(dir, 'npm.log'),
      VIBING_NVIM_RPC_PORT: '',
      VIBING_MCP_REBUILD_GRACE_MS: '0',
    },
    encoding: 'utf8',
    timeout: 60_000,
  });
}

test('spending the deadline on a build is reported to Neovim', async () => {
  const dir = await makeTree();
  const received = [];
  const server = net.createServer((socket) => {
    socket.on('data', (chunk) => {
      for (const line of chunk.toString().split('\n')) {
        if (line.length > 0) received.push(JSON.parse(line));
      }
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));

  try {
    // Nothing runnable in dist/, so this is the one path that still spends the startup budget --
    // and the only one that can still end with no tools in the session. It has to say so, and
    // stderr is not a channel that reaches anyone (see bin/notify-nvim.mjs).
    const { code } = runLauncher(dir, { VIBING_NVIM_RPC_PORT: String(server.address().port) });
    assert.equal(code, 0);

    await eventually(() => received.length > 0, 'the launcher to notify Neovim');
    const [request] = received;
    assert.equal(request.method, 'notify');
    assert.equal(request.params.level, 'warn');
    assert.match(request.params.message, /build\.sh/);
  } finally {
    server.close();
    await rm(dir, { recursive: true, force: true });
  }
});
