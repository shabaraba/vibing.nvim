import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const PERF_DIR = join(dirname(fileURLToPath(import.meta.url)), 'perf');

// Everything under tests/perf/ spends real tokens, and `test:lua` sweeps the whole of `tests/`.
// Today these files are out of its reach only because plenary collects `*_spec.lua` and none of
// them is one -- a single rename is all it would take to make `npm test` spend real money
// unattended. #777 shipped `duplex_latency.lua` with no guard at all for exactly this reason, so
// the guard is asserted here rather than left to whoever adds the next harness.
test('every tests/perf/ harness refuses to run without VIBING_PERF=1', () => {
  const files = readdirSync(PERF_DIR).filter((f) => f.endsWith('.lua') || f.endsWith('.sh'));

  assert.ok(files.length > 0, 'tests/perf/ should contain harnesses; found none');

  for (const file of files) {
    const source = readFileSync(join(PERF_DIR, file), 'utf8');
    assert.match(
      source,
      /VIBING_PERF/,
      `${file} must gate itself on VIBING_PERF before spending tokens`
    );
    // The variable appearing somewhere is not the guard; an early exit when it is unset is.
    assert.match(
      source,
      /(getenv\("VIBING_PERF"\)\s*~=\s*"1"|\$\{VIBING_PERF:-\}"?\s*!=\s*"1")/,
      `${file} mentions VIBING_PERF but does not bail out when it is unset`
    );
  }
});
