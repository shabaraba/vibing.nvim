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
 * `tests/`, and return the exit code.
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
    return result.status;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test('passing specs exit 0', async () => {
  assert.equal(await runSuite({ 'a_spec.lua': PASSING_SPEC, 'b_spec.lua': PASSING_SPEC }), 0);
});

test('one failing spec among passing ones fails the run', async () => {
  const code = await runSuite({ 'a_spec.lua': PASSING_SPEC, 'b_spec.lua': FAILING_SPEC });
  assert.notEqual(code, 0, 'a failing spec must not be masked by its passing neighbours');
});

test('a spec that cannot be loaded fails the run', async () => {
  const code = await runSuite({ 'a_spec.lua': PASSING_SPEC, 'b_spec.lua': UNLOADABLE_SPEC });
  assert.notEqual(code, 0, 'a spec that vanishes at load time must not pass silently');
});
