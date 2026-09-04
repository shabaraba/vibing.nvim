#!/usr/bin/env node
/**
 * claude-plugin/mcp-server/bin/run.mjs runs before the MCP server exists, inside the 30s Claude
 * Code allows a plugin's server to start. Everything it spends there comes out of that budget.
 *
 * A plain `npm ci` does not fit in it. Measured against a warm cache on macOS, the audit and
 * funding round-trips plus metadata revalidation take 31s on their own — so any commit that
 * leaves the build stale (a `git pull` touching src/, say) makes the launcher time out on every
 * turn, and the whole vibing-nvim tool set vanishes from the session with no error anywhere.
 * Nothing else in the project notices: the failure is a missing tool, not a failing command.
 *
 * These tests run the real launcher against a throwaway mcp-server tree with a fake `npm` first on
 * PATH, so they assert on the argv it actually passes rather than on the text of the file.
 */

import { strict as assert } from 'assert';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, copyFile, writeFile, chmod, rm } from 'fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const launcherDir = join(repoRoot, 'claude-plugin/mcp-server/bin');

/**
 * A stand-in for npm that records its argv and, for `run build`, produces the dist/ output the
 * launcher goes on to require. Exiting 0 without it would make the launcher fail for a reason
 * these tests are not about.
 */
const FAKE_NPM = `#!/bin/sh
printf '%s\\n' "$*" >> "$NPM_LOG"
if [ "$1" = "run" ]; then
  mkdir -p dist
  echo 'process.exit(0)' > dist/index.js
fi
exit 0
`;

/** Build a throwaway tree shaped like claude-plugin/mcp-server/, with the real launcher in it. */
async function makeTree() {
  const dir = await mkdtemp(join(tmpdir(), 'vibing-launcher-'));
  await mkdir(join(dir, 'mcp/bin'), { recursive: true });
  await mkdir(join(dir, 'mcp/src'), { recursive: true });
  await mkdir(join(dir, 'fakebin'), { recursive: true });

  for (const file of ['run.mjs', 'build-fingerprint.mjs']) {
    await copyFile(join(launcherDir, file), join(dir, 'mcp/bin', file));
  }
  await writeFile(join(dir, 'mcp/package.json'), '{ "name": "stub", "version": "0.0.0" }\n');
  await writeFile(join(dir, 'mcp/src/index.ts'), 'export const x = 1;\n');

  const npm = join(dir, 'fakebin/npm');
  await writeFile(npm, FAKE_NPM);
  await chmod(npm, 0o755);

  return dir;
}

/** Run the launcher in `dir`, and return its exit code plus one entry per npm invocation. */
function runLauncher(dir) {
  const log = join(dir, 'npm.log');
  const result = spawnSync(process.execPath, [join(dir, 'mcp/bin/run.mjs')], {
    env: { ...process.env, PATH: `${join(dir, 'fakebin')}:${process.env.PATH}`, NPM_LOG: log },
    encoding: 'utf8',
    timeout: 60_000,
  });
  assert.notEqual(result.status, null, `launcher did not exit: ${result.error ?? 'unknown'}`);
  const calls = existsSync(log)
    ? readFileSync(log, 'utf8')
        .split('\n')
        .filter((line) => line.length > 0)
    : [];
  return { code: result.status, stderr: result.stderr, calls };
}

test('the self-build keeps npm off the registry', async () => {
  const dir = await makeTree();
  try {
    const { calls } = runLauncher(dir);
    const install = calls.find((call) => call.startsWith('ci'));
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

test('a stale tree is rebuilt and the compiled server is launched', async () => {
  const dir = await makeTree();
  try {
    const { code, calls, stderr } = runLauncher(dir);
    assert.equal(code, 0, `launcher failed: ${stderr}`);
    assert.equal(calls.length, 2, `expected an install and a build, got ${JSON.stringify(calls)}`);
    assert.ok(calls[1].startsWith('run build'));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('a tree already built for this source is launched without touching npm', async () => {
  const dir = await makeTree();
  try {
    // node_modules/ is one of the three things isBuildStale checks for; the fake npm does not
    // create it, so without this the second run would rebuild for a reason unrelated to the
    // fingerprint.
    await mkdir(join(dir, 'mcp/node_modules'), { recursive: true });
    runLauncher(dir);
    await rm(join(dir, 'npm.log'));

    const { code, calls } = runLauncher(dir);
    assert.equal(code, 0);
    assert.deepEqual(calls, [], 'an unchanged tree spent a build it did not need');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
