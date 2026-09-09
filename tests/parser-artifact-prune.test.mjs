#!/usr/bin/env node
/**
 * `vim.treesitter.language.add('vibing')` globs `parser/vibing.*` and loads the *first* match, not
 * `vibing.so` specifically. So a leftover library in that directory is not inert: one whose name
 * sorts earlier is loaded instead of the parser build.sh just produced, and the symptom is a
 * grammar that disagrees with `queries/vibing/*.scm` ("Invalid node type ..."), not a missing
 * parser. `/parser/` is git-ignored, so such a file never appears in `git status` either.
 *
 * Two things keep that from happening, and both are asserted here because both are one careless
 * edit away from reverting: build.sh prunes the directory before it builds, and its own temporary
 * file is named so it cannot match the glob in the first place.
 */

import { strict as assert } from 'assert';
import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const buildScript = readFileSync(join(repoRoot, 'build.sh'), 'utf8');

/** The shell function under test, lifted out of build.sh so no npm install has to run. */
function extractPruneFunction() {
  const match = buildScript.match(/^prune_stale_parser_artifacts\(\) \{\n[\s\S]*?^\}$/m);
  assert.ok(
    match,
    'prune_stale_parser_artifacts() not found in build.sh — if it was renamed, rename it here too ' +
      'rather than letting this test pass by exercising nothing'
  );
  return match[0];
}

test('the pruner removes every stale vibing parser artifact and keeps the real one', () => {
  const dir = mkdtempSync(join(tmpdir(), 'vibing-parser-prune-'));
  try {
    const strays = [
      'vibing.so.tmp.4242', // an interrupted build's temporary file, pre-fix naming
      '.vibing.so.tmp.777', // ... and post-fix naming
      'vibing.dylib', // sorts before vibing.so, so this one would actually be loaded
      'vibing.wasm',
    ];
    for (const name of [...strays, 'vibing.so', 'markdown.so']) {
      writeFileSync(join(dir, name), '');
    }

    execFileSync('bash', ['-c', `${extractPruneFunction()}\nprune_stale_parser_artifacts`], {
      env: { ...process.env, VIBING_PARSER_OUTPUT_DIR: dir },
    });

    // markdown.so stands in for a parser the user put here themselves: the sweep is scoped to
    // vibing's own artifacts, not to everything on the runtime path.
    assert.deepEqual(readdirSync(dir).sort(), ['markdown.so', 'vibing.so']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("build.sh's temporary parser file cannot match Neovim's parser/vibing.* glob", () => {
  const assignment = buildScript.match(/^\s*local (parser_tmp="[^"]+")$/m);
  assert.ok(assignment, 'parser_tmp assignment not found in build.sh');

  // Expanded by bash rather than inspected as text: the pre-fix spelling was
  // "${parser_output}.tmp.$$", whose hazardous basename only appears once the variables are
  // resolved. A string comparison would read that as safe.
  const basename = execFileSync(
    'bash',
    [
      '-c',
      [
        'VIBING_PARSER_OUTPUT_DIR=/tmp/vibing-parser-glob-check',
        'parser_output="${VIBING_PARSER_OUTPUT_DIR}/vibing.so"',
        assignment[1],
        'basename "$parser_tmp"',
      ].join('\n'),
    ],
    { encoding: 'utf8' }
  ).trim();

  assert.ok(
    !/^vibing\./.test(basename),
    `parser_tmp resolves to "${basename}", which matches parser/vibing.* and can be loaded ` +
      'instead of the built parser if the build is killed before it renames the file'
  );
});
