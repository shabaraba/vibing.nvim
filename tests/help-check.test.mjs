#!/usr/bin/env node
/**
 * scripts/check-help.lua is the only thing in CI that reads doc/*.txt, and CI reads nothing but
 * its exit code. These tests pin that exit code against each failure it is supposed to catch --
 * a gate that cannot fail is how doc/vibing.txt went unchecked in the first place (#542).
 *
 * The two width tests are the point of the exercise. Measuring bytes flags the • and — already
 * in vibing.txt as overlong; measuring characters lets a CJK line run to 156 columns. Only
 * Vim's own strdisplaywidth gets both right, which is why the checker runs inside nvim.
 */

import { strict as assert } from 'assert';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'fs/promises';
import { dirname, join } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');

/** A minimal but valid help file, used as the base every failure case deviates from. */
function helpFile({ contents, body }) {
  return [
    '*fixture.txt*  fixture',
    '',
    '='.repeat(78),
    'CONTENTS                                                    *fixture-contents*',
    '',
    ...contents,
    '',
    '='.repeat(78),
    ...body,
    '',
  ].join('\n');
}

const VALID = helpFile({
  contents: ['    1. One ..................................... |fixture-one|'],
  body: [
    '1. ONE                                                           *fixture-one*',
    '',
    'Body.',
  ],
});

/** Run the checker over `dir` (or the repository's own doc/) and return its exit code. */
function check(dir) {
  const result = spawnSync(
    'nvim',
    ['--headless', '-l', 'scripts/check-help.lua', ...(dir ? [dir] : [])],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      timeout: 60_000,
    }
  );

  assert.notEqual(result.status, null, `nvim did not exit: ${result.error ?? 'unknown'}`);
  return { code: result.status, stderr: result.stderr };
}

/** Write `text` as the sole help file in a throwaway directory and check it. */
async function checkText(text) {
  const dir = await mkdtemp(join(tmpdir(), 'vibing-help-'));
  try {
    await writeFile(join(dir, 'fixture.txt'), text);
    return check(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test("the repository's own doc/ passes", () => {
  const { code, stderr } = check();
  assert.equal(code, 0, `doc/ must stay valid:\n${stderr}`);
});

test('a well-formed fixture passes', async () => {
  const { code, stderr } = await checkText(VALID);
  assert.equal(code, 0, stderr);
});

test('a duplicate tag fails, because helptags refuses to generate', async () => {
  const { code, stderr } = await checkText(`${VALID}\n\nSaid twice *fixture-one*\n`);
  assert.equal(code, 1);
  assert.match(stderr, /helptags/);
});

test('a line wider than 78 columns fails', async () => {
  const { code, stderr } = await checkText(`${VALID}\n${'x'.repeat(79)}\n`);
  assert.equal(code, 1);
  assert.match(stderr, /79 columns/);
});

test('a 78-column line that exceeds 78 bytes passes', async () => {
  // 76 ASCII + two 3-byte characters: 78 columns, 82 bytes. A byte count would reject this,
  // and lines exactly like it already exist in doc/vibing.txt.
  const line = `${'x'.repeat(76)}•—`;
  assert.equal(Buffer.byteLength(line), 82);

  const { code, stderr } = await checkText(`${VALID}\n${line}\n`);
  assert.equal(code, 0, stderr);
});

test('a 78-character CJK line fails, because it occupies 156 columns', async () => {
  // A character count would accept this. Vim renders it at double width.
  const line = '日'.repeat(78);
  assert.equal([...line].length, 78);

  const { code, stderr } = await checkText(`${VALID}\n${line}\n`);
  assert.equal(code, 1);
  assert.match(stderr, /156 columns/);
});

test('a CONTENTS entry pointing at an undefined tag fails', async () => {
  const text = helpFile({
    contents: ['    1. One ..................................... |fixture-nowhere|'],
    body: [
      '1. ONE                                                           *fixture-one*',
      '',
      'Body.',
    ],
  });

  const { code, stderr } = await checkText(text);
  assert.equal(code, 1);
  assert.match(stderr, /fixture-nowhere/);
});

test('a section numbered out of step with CONTENTS fails', async () => {
  const text = helpFile({
    contents: [
      '    1. One ..................................... |fixture-one|',
      '    2. Two ..................................... |fixture-two|',
    ],
    body: [
      '1. ONE                                                           *fixture-one*',
      '',
      'Body.',
      '',
      '='.repeat(78),
      '3. TWO                                                           *fixture-two*',
      '',
      'Body.',
    ],
  });

  const { code, stderr } = await checkText(text);
  assert.equal(code, 1);
  assert.match(stderr, /does not match section 3/);
});

test('a section missing from CONTENTS fails', async () => {
  const text = helpFile({
    contents: ['    1. One ..................................... |fixture-one|'],
    body: [
      '1. ONE                                                           *fixture-one*',
      '',
      'Body.',
      '',
      '='.repeat(78),
      '2. TWO                                                           *fixture-two*',
      '',
      'Body.',
    ],
  });

  const { code, stderr } = await checkText(text);
  assert.equal(code, 1);
  assert.match(stderr, /missing from CONTENTS/);
});
