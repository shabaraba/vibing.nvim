import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * A spec that budgets more time than the harness gives it cannot report anything.
 *
 * `PlenaryBustedDirectory` runs one child Neovim per spec **file** and joins it with a single
 * timeout (`plenary/test_harness.lua`, default 50000ms). A spec still inside a `vim.wait` when
 * that expires is killed mid-wait: it prints no summary, no failure, no test count — only the
 * suite's exit code moves. That is the same dead-gate shape `.claude/rules/self-testing.md`
 * documents for a spec file that runs zero tests, and it is how three E2E specs (each budgeting
 * 60000ms against the 50000ms default) sat silently broken.
 *
 * The number that has to hold is per file, not per test, because the timeout is on the job. So
 * this sums every wait a file can perform and requires the total to fit.
 *
 * It reads both sides out of the repository rather than restating them: the harness budget comes
 * from the actual `test:e2e` command, so the check cannot pass against a command the project no
 * longer runs (the same reasoning as `lua-syntax-gate.test.mjs`).
 */

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/** plenary's own default when `PlenaryBustedDirectory` is given no `timeout` (test_harness.lua). */
const PLENARY_DEFAULT_TIMEOUT_MS = 50000;

function harnessTimeoutMs() {
  const { scripts } = JSON.parse(readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
  const command = scripts['test:e2e'];
  assert.ok(command, 'package.json must still define a test:e2e script');
  assert.match(
    command,
    /PlenaryBusted/,
    'test:e2e no longer runs plenary; this gate encodes plenary’s per-file job timeout'
  );

  const explicit = command.match(/timeout\s*=\s*(\d+)/);
  return explicit ? Number(explicit[1]) : PLENARY_DEFAULT_TIMEOUT_MS;
}

/** `local TIMEOUTS = { KEY = 1234, ... }` → { KEY: 1234 } */
function parseTimeoutTable(source) {
  const table = source.match(/local TIMEOUTS = \{([\s\S]*?)\n\}/);
  if (!table) return {};

  const values = {};
  for (const [, key, ms] of table[1].matchAll(/(\w+)\s*=\s*(\d+)/g)) {
    values[key] = Number(ms);
  }
  return values;
}

/**
 * The worst case a file can spend waiting: every `TIMEOUTS.KEY` reference at its declared value,
 * plus every `vim.wait(<literal>)`.
 *
 * Deliberately an over-estimate — a reference inside a comment or an assertion message counts
 * too. Over-counting only ever asks for a larger harness budget, which is the safe direction; a
 * clever exact model would be the thing that lets the silent case back in.
 */
function worstCaseWaitMs(source) {
  const values = parseTimeoutTable(source);
  const body = source.replace(/local TIMEOUTS = \{[\s\S]*?\n\}/, '');

  let total = 0;
  for (const [, key] of body.matchAll(/TIMEOUTS\.(\w+)/g)) {
    total += values[key] ?? 0;
  }
  for (const [, ms] of body.matchAll(/vim\.wait\(\s*(\d+)\s*\)/g)) {
    total += Number(ms);
  }
  return total;
}

function specFiles() {
  const dir = path.join(ROOT, 'tests', 'e2e');
  return readdirSync(dir)
    .filter((name) => name.endsWith('.lua'))
    .map((name) => path.join(dir, name));
}

test('every E2E spec can spend its whole budget without the harness killing it first', () => {
  const budget = harnessTimeoutMs();
  const over = [];

  for (const file of specFiles()) {
    const worstCase = worstCaseWaitMs(readFileSync(file, 'utf8'));
    if (worstCase >= budget) {
      over.push(
        `${path.relative(ROOT, file)}: waits up to ${worstCase}ms, harness allows ${budget}ms`
      );
    }
  }

  assert.deepEqual(
    over,
    [],
    'These specs would be killed mid-wait and report nothing at all — no summary, no failure, ' +
      'only the exit code. Either lower the spec’s own timeouts or raise `timeout` in the ' +
      'test:e2e script:\n' +
      over.join('\n')
  );
});

test('the gate reads a real budget, not a placeholder', () => {
  // A `test:e2e` that lost its explicit timeout silently falls back to plenary's 50s, which is
  // below what these specs need. Catch that here rather than in a run that prints nothing.
  const budget = harnessTimeoutMs();
  assert.ok(
    budget > PLENARY_DEFAULT_TIMEOUT_MS,
    `test:e2e must set an explicit timeout; got ${budget}ms`
  );
});

test('the parser actually finds the numbers it is gating on', () => {
  // Without this, a rename of the TIMEOUTS table would make every file measure 0ms and the gate
  // would pass by seeing nothing — the failure mode it exists to prevent, one level up.
  const measured = specFiles().map((file) => worstCaseWaitMs(readFileSync(file, 'utf8')));

  assert.ok(
    measured.filter((ms) => ms > 0).length >= 5,
    `expected most E2E specs to declare waits; measured ${JSON.stringify(measured)}`
  );
});
