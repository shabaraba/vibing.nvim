#!/usr/bin/env node
/**
 * scripts/check-help.lua is what CI runs over doc/*.txt, and CI reads nothing but its exit code.
 * These tests pin that exit code against each failure it is supposed to catch -- a gate that
 * cannot fail is how doc/vibing.txt went unchecked in the first place (#542). The CI step gates
 * the document; this file gates the checker.
 *
 * The two width tests are the point of the exercise: only Vim's own strdisplaywidth accepts the
 * • and — already in vibing.txt while still rejecting a CJK line, which is why the checker runs
 * inside nvim at all.
 */

import { strict as assert } from 'assert';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'fs/promises';
import { dirname, join } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');

/** `    1. One ....... |fixture-one|`, padded the way a CONTENTS row is. */
const entry = (number, title, tag) => `    ${number}. ${title} ${'.'.repeat(30)} |${tag}|`;

/** `1. ONE                    *fixture-one*`, padded the way a section heading is. */
const heading = (number, title, tag) => `${number}. ${title.toUpperCase()}`.padEnd(60) + `*${tag}*`;

const RULE = '='.repeat(78);

/** A minimal but valid help file, used as the base every failure case deviates from. */
function helpFile({ contents, body }) {
  return [
    '*fixture.txt*  fixture',
    '',
    RULE,
    `CONTENTS${' '.repeat(52)}*fixture-contents*`,
    '',
    ...contents,
    '',
    RULE,
    ...body,
    '',
  ].join('\n');
}

const VALID = helpFile({
  contents: [entry(1, 'One', 'fixture-one')],
  body: [heading(1, 'One', 'fixture-one'), '', 'Body.'],
});

/** Write `text` as the sole help file in a throwaway directory and run the checker over it. */
async function checkText(text) {
  const dir = await mkdtemp(join(tmpdir(), 'vibing-help-'));
  try {
    await writeFile(join(dir, 'fixture.txt'), text);

    const result = spawnSync('nvim', ['--headless', '-l', 'scripts/check-help.lua', dir], {
      cwd: repoRoot,
      encoding: 'utf8',
      timeout: 60_000,
    });

    assert.notEqual(result.status, null, `nvim did not exit: ${result.error ?? 'unknown'}`);
    return { code: result.status, stderr: result.stderr };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test('a well-formed help file passes', async () => {
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

const DISAGREEMENTS = [
  {
    name: 'a CONTENTS entry linking to a tag no section defines fails',
    contents: [entry(1, 'One', 'fixture-nowhere')],
    body: [heading(1, 'One', 'fixture-one')],
    expect: /fixture-nowhere/,
  },
  {
    name: 'a renumbered section is reported against its own number, not its neighbour',
    contents: [entry(1, 'One', 'fixture-one'), entry(2, 'Two', 'fixture-two')],
    body: [heading(1, 'One', 'fixture-one'), '', RULE, heading(3, 'Two', 'fixture-two')],
    expect: /body has no section 2/,
  },
  {
    name: 'a section missing from CONTENTS fails',
    contents: [entry(1, 'One', 'fixture-one')],
    body: [heading(1, 'One', 'fixture-one'), '', RULE, heading(2, 'Two', 'fixture-two')],
    expect: /missing from CONTENTS/,
  },
  {
    name: 'a CONTENTS entry with no section at all fails',
    contents: [entry(1, 'One', 'fixture-one'), entry(2, 'Two', 'fixture-two')],
    body: [heading(1, 'One', 'fixture-one')],
    expect: /body has no section 2/,
  },
];

for (const { name, contents, body, expect } of DISAGREEMENTS) {
  test(name, async () => {
    const { code, stderr } = await checkText(helpFile({ contents, body }));
    assert.equal(code, 1);
    assert.match(stderr, expect);
  });
}

test('a CONTENTS block aligned with spaces is still checked', async () => {
  // Requiring a dot leader used to make the whole CONTENTS check skip itself on a file like
  // this, reporting OK while a real mismatch sat in it. Space alignment is ordinary vimdoc.
  const text = helpFile({
    contents: [
      `    1. One${' '.repeat(30)}|fixture-one|`,
      `    2. Two${' '.repeat(30)}|fixture-two|`,
    ],
    body: [heading(1, 'One', 'fixture-one'), '', RULE, heading(5, 'Two', 'fixture-two')],
  });

  const { code, stderr } = await checkText(text);
  assert.equal(code, 1);
  assert.match(stderr, /body has no section 2/);
});

test('a CONTENTS block with no readable rows fails rather than passing', async () => {
  const text = helpFile({
    contents: ['    see the sections below'],
    body: [heading(1, 'One', 'fixture-one'), '', 'Body.'],
  });

  const { code, stderr } = await checkText(text);
  assert.equal(code, 1);
  assert.match(stderr, /no `N\. Title \|tag\|` rows/);
});

test('a help file with no CONTENTS block at all passes', async () => {
  const text = [
    '*fixture.txt*  fixture',
    '',
    RULE,
    heading(1, 'One', 'fixture-one'),
    '',
    'Body.',
    '',
  ].join('\n');

  const { code, stderr } = await checkText(text);
  assert.equal(code, 0, stderr);
});

test('a numbered body line ending in a |tag| is not mistaken for a CONTENTS entry', async () => {
  // CONTENTS rows are indented, so unlike a section heading their pattern cannot be anchored at
  // column 0. Scanning the whole file for it also matched a line like the one below, shifting
  // every index after it and reporting a section that is present as missing.
  const text = helpFile({
    contents: [entry(1, 'One', 'fixture-one'), entry(2, 'Two', 'fixture-two')],
    body: [
      heading(1, 'One', 'fixture-one'),
      '',
      RULE,
      heading(2, 'Two', 'fixture-two'),
      '',
      'Troubleshooting:',
      '',
      '    4. See |fixture-one|',
    ],
  });

  const { code, stderr } = await checkText(text);
  assert.equal(code, 0, stderr);
});

test('one renumbered section does not cascade into its neighbours', async () => {
  // Walking the two lists in parallel turned a single mistake into a message per section after
  // it, and the first one named a section that was fine. Number-keyed matching reports the two
  // facts about section 3 and says nothing about sections 1 or 2.
  const text = helpFile({
    contents: [
      entry(1, 'One', 'fixture-one'),
      entry(2, 'Two', 'fixture-two'),
      entry(3, 'Three', 'fixture-three'),
    ],
    body: [
      heading(1, 'One', 'fixture-one'),
      '',
      RULE,
      heading(2, 'Two', 'fixture-two'),
      '',
      RULE,
      heading(9, 'Three', 'fixture-three'),
    ],
  });

  const { code, stderr } = await checkText(text);
  assert.equal(code, 1);
  assert.match(stderr, /2 problem/);
  assert.doesNotMatch(stderr, /section 1\b/);
});

test('a duplicated section number in CONTENTS is reported', async () => {
  const text = helpFile({
    contents: [entry(1, 'One', 'fixture-one'), entry(1, 'Again', 'fixture-again')],
    body: [heading(1, 'One', 'fixture-one')],
  });

  const { code, stderr } = await checkText(text);
  assert.equal(code, 1);
  assert.match(stderr, /lists section 1 more than once/);
});

test('a duplicated section number in the body is reported', async () => {
  const text = helpFile({
    contents: [entry(1, 'One', 'fixture-one')],
    body: [heading(1, 'One', 'fixture-one'), '', RULE, heading(1, 'Again', 'fixture-again')],
  });

  const { code, stderr } = await checkText(text);
  assert.equal(code, 1);
  assert.match(stderr, /more than one section numbered 1/);
});

test('sub-section numbering fails rather than being skipped in silence', async () => {
  // Neither pattern can read `2.1`, so it used to drop out of the comparison without a word --
  // checked-looking and unchecked.
  const text = helpFile({
    contents: [entry(1, 'One', 'fixture-one'), '    2.1 Sub ......... |fixture-sub|'],
    body: [heading(1, 'One', 'fixture-one')],
  });

  const { code, stderr } = await checkText(text);
  assert.equal(code, 1);
  assert.match(stderr, /sub-section numbering/);
});

test('a directory with no help file at all fails', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'vibing-help-'));
  try {
    const result = spawnSync('nvim', ['--headless', '-l', 'scripts/check-help.lua', dir], {
      cwd: repoRoot,
      encoding: 'utf8',
      timeout: 60_000,
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /no \*\.txt help file/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('every help file in the directory is checked, not just the first', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'vibing-help-'));
  try {
    await writeFile(join(dir, 'a.txt'), VALID);
    // Second file is fine except for one overlong line.
    await writeFile(join(dir, 'b.txt'), `${VALID}\n${'x'.repeat(90)}\n`);

    const result = spawnSync('nvim', ['--headless', '-l', 'scripts/check-help.lua', dir], {
      cwd: repoRoot,
      encoding: 'utf8',
      timeout: 60_000,
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /b\.txt:\d+: 90 columns/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('an indented N.M line in the body is prose, not an unchecked sub-section', async () => {
  // The subsection scan used to run over the whole file, so a `>` code example or an ordinary
  // paragraph starting with `2.1` tripped it. Same class of bug as the CONTENTS row scan.
  const text = helpFile({
    contents: [entry(1, 'One', 'fixture-one')],
    body: [
      heading(1, 'One', 'fixture-one'),
      '',
      'Example: >',
      '    2.1 is a ratio, not a heading',
      '<',
      '',
      '    3.5 mm of travel.',
    ],
  });

  const { code, stderr } = await checkText(text);
  assert.equal(code, 0, stderr);
});

test('a real sub-section at column 0 is still caught', async () => {
  const text = helpFile({
    contents: [entry(1, 'One', 'fixture-one')],
    body: [
      heading(1, 'One', 'fixture-one'),
      '',
      RULE,
      '2.1 SUB' + ' '.repeat(50) + '*fixture-sub*',
    ],
  });

  const { code, stderr } = await checkText(text);
  assert.equal(code, 1);
  assert.match(stderr, /sub-section numbering/);
});

test('a number repeated three times is reported once, not twice', async () => {
  const text = helpFile({
    contents: [
      entry(1, 'One', 'fixture-one'),
      entry(1, 'Again', 'fixture-again'),
      entry(1, 'Thrice', 'fixture-thrice'),
    ],
    body: [heading(1, 'One', 'fixture-one')],
  });

  const { code, stderr } = await checkText(text);
  assert.equal(code, 1);
  assert.equal(stderr.match(/lists section 1 more than once/g).length, 1);
});
