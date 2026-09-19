#!/usr/bin/env node
/**
 * CI's Lua test gate is nothing but the exit code of `npm run test:lua`, so that exit code
 * is the only thing standing between a broken spec and a green build. These tests pin it.
 *
 * The gate used to grep the output for `Failed : 0` instead. PlenaryBustedDirectory prints
 * one summary per spec file, so that line was always present and the job passed no matter
 * how many specs failed (issue #561).
 */

import { strict as assert } from 'assert';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'fs/promises';
import { dirname, join } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');

const PASSING_SPEC = `
describe("passing", function()
  it("passes", function()
    assert.equals(1, 1)
  end)
end)
`;

const FAILING_SPEC = `
describe("failing", function()
  it("fails", function()
    assert.equals(1, 2)
  end)
end)
`;

// Not valid Lua: the file never loads, so it contributes no summary line at all.
const UNLOADABLE_SPEC = `describe("unloadable", function(`;

/**
 * Run the suite over a throwaway directory the same way `npm run test:lua` runs it over
 * `tests/`, and return the finished child.
 */
async function runSuite(specs) {
  const dir = await mkdtemp(join(tmpdir(), 'vibing-lua-exit-'));
  try {
    for (const [name, body] of Object.entries(specs)) {
      await writeFile(join(dir, name), body);
    }

    const result = spawnSync(
      'nvim',
      [
        '--headless',
        '-u',
        'tests/minimal_init.lua',
        '-c',
        `PlenaryBustedDirectory ${dir} { minimal_init = 'tests/minimal_init.lua' }`,
      ],
      // `npm run test:node` has no step-level timeout of its own, so bound the child here:
      // a nvim that never exits leaves `status` null, which the assertion below fails on.
      { cwd: repoRoot, encoding: 'utf8', timeout: 120_000 }
    );

    assert.notEqual(result.status, null, `nvim did not exit: ${result.error ?? 'unknown'}`);
    return result;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test('passing specs exit 0', async () => {
  const { status } = await runSuite({ 'a_spec.lua': PASSING_SPEC, 'b_spec.lua': PASSING_SPEC });
  assert.equal(status, 0);
});

test('one failing spec among passing ones fails the run', async () => {
  const { status } = await runSuite({ 'a_spec.lua': PASSING_SPEC, 'b_spec.lua': FAILING_SPEC });
  assert.notEqual(status, 0, 'a failing spec must not be masked by its passing neighbours');
});

test('a spec that cannot be loaded fails the run', async () => {
  const { status } = await runSuite({ 'a_spec.lua': PASSING_SPEC, 'b_spec.lua': UNLOADABLE_SPEC });
  assert.notEqual(status, 0, 'a spec that vanishes at load time must not pass silently');
});

/** Match "Test environment initialized: <root>" for a literal root. */
function initializedWith(root) {
  return new RegExp(
    `Test environment initialized: ${root.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(\\s|$)`
  );
}

test('the run says which checkout it loaded', async () => {
  // `-u tests/minimal_init.lua` is relative, so the cwd the command was typed in decides which
  // checkout is tested. Running from the wrong one is green and reports on code the developer
  // never touched; no script can tell that the caller meant a different tree, so the only
  // defence is that the run names the tree out loud. Keep this line printed.
  const { stdout, stderr } = await runSuite({ 'a_spec.lua': PASSING_SPEC });

  assert.match(
    stdout + stderr,
    initializedWith(repoRoot),
    'tests/minimal_init.lua no longer prints the plugin root it resolved'
  );
});

test('the printed root is the tree that was loaded, not the cwd', async () => {
  // The whole point is to distinguish those two, so an attribution taken from `getcwd()` would
  // be no attribution at all -- and it reads as correct every time the two agree, which is
  // every ordinary run. Drive them apart: absolute `-u`, cwd somewhere else entirely.
  const elsewhere = await mkdtemp(join(tmpdir(), 'vibing-init-cwd-'));
  try {
    const result = spawnSync(
      'nvim',
      ['--headless', '-u', join(repoRoot, 'tests/minimal_init.lua'), '-c', 'quitall!'],
      { cwd: elsewhere, encoding: 'utf8', timeout: 120_000 }
    );
    assert.notEqual(result.status, null, `nvim did not exit: ${result.error ?? 'unknown'}`);

    const output = result.stdout + result.stderr;
    assert.match(output, initializedWith(repoRoot), 'the root named was not the loaded tree');
    assert.doesNotMatch(output, initializedWith(elsewhere), 'the root named was the cwd');
  } finally {
    await rm(elsewhere, { recursive: true, force: true });
  }
});
