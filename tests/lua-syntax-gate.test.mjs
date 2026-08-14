#!/usr/bin/env node
/**
 * CI's "Run Lua syntax check" step is `npm run check`, and it reads nothing but the exit code.
 *
 * That step spent its whole life unable to fail. `find ... -exec luac -p {} \;` reports the exit
 * status of `find`, not of `luac`, so a Lua file that would not compile printed an error and the
 * job went green -- the same shape of dead gate as #561, found while adding the help-file check
 * for #542. `-exec ... +` propagates, and these tests hold it to that.
 *
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

/** Run the project's `check` command over a throwaway tree containing `files`, and return its code. */
async function runCheck(files) {
  const dir = await mkdtemp(join(tmpdir(), 'vibing-luac-'));
  try {
    await mkdir(join(dir, 'lua'), { recursive: true });
    for (const [name, body] of Object.entries(files)) {
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
  assert.notEqual(code, 0, 'luac -p rejected the file but the command reported success');
});

test('a broken file fails even when it sorts before the valid ones', async () => {
  // `-exec ... +` batches every path into one luac invocation, so this is not a "last one wins"
  // situation the way a per-file loop would be -- but it is the case a naive fix gets wrong.
  const code = await runCheck({ 'a_broken.lua': 'function(\n', 'z_ok.lua': 'return 1\n' });
  assert.notEqual(code, 0);
});
