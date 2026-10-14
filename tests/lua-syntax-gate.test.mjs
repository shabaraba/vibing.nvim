#!/usr/bin/env node
/**
 * CI's "Run Lua syntax check" step is `npm run check`, and it reads nothing but the exit code.
 *
 * That step spent its whole life unable to fail. `find ... -exec luac -p {} \;` reports the exit
 * status of `find`, not of `luac`, so a Lua file that would not compile printed an error and the
 * job went green -- the same shape of dead gate as #561, found while adding the help-file check
 * for #542. Switching to `-exec ... +` first fixed exit-code propagation.
 *
 * The current gate compiles with Neovim's parser, without requiring a separate luac installation.
 * The command is read out of package.json rather than restated here, so the test cannot pass
 * against a command the project no longer runs.
 */

import { strict as assert } from 'assert';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, rm, readFile } from 'fs/promises';
import { dirname, join } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');

const checkCommand = JSON.parse(await readFile(join(repoRoot, 'package.json'), 'utf8')).scripts
  .check;
const checkerSource = await readFile(join(repoRoot, 'scripts/check-lua.lua'), 'utf8');

/** Run the project's `check` command over a throwaway tree containing `files`, and return its code. */
async function runCheck(files) {
  const dir = await mkdtemp(join(tmpdir(), 'vibing-lua-check-'));
  try {
    await mkdir(join(dir, 'lua'), { recursive: true });
    await mkdir(join(dir, 'scripts'));
    await writeFile(join(dir, 'scripts/check-lua.lua'), checkerSource);
    for (const [name, body] of Object.entries(files)) {
      await mkdir(dirname(join(dir, 'lua', name)), { recursive: true });
      await writeFile(join(dir, 'lua', name), body);
    }

    const result = spawnSync(checkCommand, {
      cwd: dir,
      shell: true,
      encoding: 'utf8',
      timeout: 60_000,
    });
    assert.notEqual(result.status, null, `check did not exit: ${result.error ?? 'unknown'}`);
    return result.status;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test('valid Lua exits 0', async () => {
  assert.equal(await runCheck({ 'a.lua': 'return 1\n', 'b.lua': 'local x = 2\nreturn x\n' }), 0);
});

test('a file that will not compile fails the run', async () => {
  const code = await runCheck({ 'a.lua': 'return 1\n', 'b.lua': 'this is not lua((\n' });
  assert.notEqual(code, 0, 'invalid Lua must fail the syntax gate');
});

test('a broken file fails even when it sorts before the valid ones', async () => {
  // The checker must retain earlier failures instead of returning only the last file's result.
  const code = await runCheck({ 'a_broken.lua': 'function(\n', 'z_ok.lua': 'return 1\n' });
  assert.notEqual(code, 0);
});

test('a broken nested file is checked', async () => {
  assert.notEqual(await runCheck({ 'a.lua': 'return 1\n', 'nested/broken.lua': 'function(\n' }), 0);
});

test('an empty tree fails instead of reporting an unchecked success', async () => {
  assert.notEqual(await runCheck({}), 0);
});

test('valid files are compiled without executing them', async () => {
  assert.equal(await runCheck({ 'a.lua': 'error("the checker executed this file")\n' }), 0);
});
