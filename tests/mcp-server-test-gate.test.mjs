#!/usr/bin/env node
/**
 * claude-plugin/mcp-server's 193 vitest tests were in no gate at all: `test:node` sweeps the
 * repository root's `tests/` for `*.test.mjs`, and CI only checked that the directory existed
 * (#790). This file pins the gate that now runs them -- `npm run test:mcp` -- the way
 * lua-syntax-gate.test.mjs pins `npm run check`.
 *
 * Six things, and the last two are the ones that matter. A gate can be wired up (a), exclude the
 * build output (b), propagate a failure (c) and refuse to run without dependencies (d) while
 * collecting zero test files -- which is indistinguishable from a green run and is exactly the
 * state #790 records. A single mistyped character in vitest.config.mjs's `include`, or that
 * config not being read at all, passes every other check here and is caught only by (e). And an
 * `include` that collects *most* of the suite hides under (e)'s lower bound, so (f) pins the one
 * narrowing that is easy to write by accident: the filename half of the glob.
 *
 * The commands are read out of package.json rather than restated, so these tests cannot pass
 * against a command the project no longer runs.
 */

import { strict as assert } from 'assert';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdtemp, mkdir, writeFile, readFile, rm, copyFile, symlink } from 'fs/promises';
import { dirname, join, sep } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const serverDir = join(repoRoot, 'claude-plugin', 'mcp-server');

const scripts = JSON.parse(await readFile(join(repoRoot, 'package.json'), 'utf8')).scripts;

/** Run the project's `test:mcp` command, optionally against another server directory. */
function runGate({ dir, args = [] } = {}) {
  return spawnSync(`${scripts['test:mcp']} ${args.join(' ')}`.trim(), {
    cwd: repoRoot,
    shell: true,
    encoding: 'utf8',
    timeout: 180_000,
    env: dir ? { ...process.env, VIBING_MCP_SERVER_DIR: dir } : process.env,
  });
}

/** The test files vitest actually collected, from its JSON report. */
function collectedFiles(report) {
  return (report.testResults ?? []).map((r) => r.name);
}

/** Just the basenames, for assertions that are about which files rather than where they are. */
function collectedNames(report) {
  return collectedFiles(report)
    .map((f) => f.split(sep).pop())
    .sort();
}

/**
 * The JSON report, or a failure that explains itself.
 *
 * `--reporter=json` writes no file at all when vitest never started, and by far the commonest
 * reason for that is the one (d) is about: the MCP server's dependencies are not installed.
 * `test:node` runs **before** `test:mcp` in the `test` chain, so in a fresh worktree -- which is
 * this repository's normal state, one per issue -- these tests are the first thing to fail, and
 * what greeted the developer was `ENOENT ... report.json` on a temp path. The command that fixes
 * it was already written, in `scripts/run-mcp-server-tests.mjs`, and was two steps further down
 * the chain than anyone got. So carry the gate's own words up here rather than reporting a
 * missing temp file as if that were the problem.
 */
async function readReport(out, result) {
  if (!existsSync(out)) {
    assert.fail(
      `the gate wrote no JSON report (exit ${result.status}), so nothing below could be ` +
        `checked. What it said instead:\n${result.stderr || result.stdout || '(no output)'}`
    );
  }
  return JSON.parse(await readFile(out, 'utf8'));
}

/**
 * A throwaway server directory: the real vitest.config.mjs, the real node_modules, and whatever
 * test files the caller asks for. Testing against the real config is the point -- a copy written
 * here would pass while the shipped one was wrong.
 */
async function scratchServer(files) {
  const dir = await mkdtemp(join(tmpdir(), 'vibing-mcp-gate-'));
  await mkdir(join(dir, 'src'), { recursive: true });
  await copyFile(join(serverDir, 'vitest.config.mjs'), join(dir, 'vitest.config.mjs'));
  await writeFile(join(dir, 'package.json'), JSON.stringify({ name: 'scratch', type: 'module' }));
  if (files !== null) {
    await symlink(join(serverDir, 'node_modules'), join(dir, 'node_modules'));
    for (const [name, body] of Object.entries(files)) {
      await writeFile(join(dir, 'src', name), body);
    }
  }
  return dir;
}

test('(a) the root test script runs the MCP server suite', () => {
  assert.match(
    scripts.test,
    /test:mcp/,
    '`npm test` no longer reaches the MCP server suite -- the #790 state, restored'
  );
  assert.match(scripts['test:mcp'], /scripts\/run-mcp-server-tests\.mjs/);
});

test('(b) the compiled copies under dist/ are not collected', async () => {
  // Real tree, not a scratch one: tsc writes dist/__tests__/*.test.js next to the sources, and
  // vitest's default include glob matched both -- so with a build present every test ran twice
  // and a stale dist/ passed green over sources that had moved underneath it.
  const distTests = join(serverDir, 'dist', '__tests__');
  const planted = join(distTests, 'dist-collection-guard.test.js');
  const distExisted = existsSync(join(serverDir, 'dist'));
  const out = join(await mkdtemp(join(tmpdir(), 'vibing-mcp-report-')), 'report.json');

  await mkdir(distTests, { recursive: true });
  // Written to fail, so that a collected dist/ turns the gate itself red and not only this
  // assertion. What is asserted, though, is which files were collected -- keying on the exit
  // code would make every genuinely broken MCP server test fail here too, under a message
  // about dist/ that has nothing to do with it.
  await writeFile(
    planted,
    "import { test } from 'vitest';\n" +
      "test('collected from dist/', () => {\n" +
      "  throw new Error('vitest collected a file under dist/');\n" +
      '});\n'
  );

  try {
    const result = runGate({ args: ['--reporter=json', `--outputFile=${out}`] });
    const collected = collectedFiles(await readReport(out, result));
    const fromDist = collected.filter((f) => f.includes(`${sep}dist${sep}`));
    assert.deepEqual(fromDist, [], `vitest collected build output:\n${result.stdout}`);
    assert.ok(collected.length > 0, 'nothing was collected, so this proves nothing -- see (e)');
  } finally {
    await rm(planted, { force: true });
    if (!distExisted) await rm(join(serverDir, 'dist'), { recursive: true, force: true });
    await rm(dirname(out), { recursive: true, force: true });
  }
});

test('(c) a failing test fails the gate, and the failure came from vitest', async () => {
  const dir = await scratchServer({
    'ok.test.ts': "import { test, expect } from 'vitest';\ntest('ok', () => expect(1).toBe(1));\n",
    'broken.test.ts':
      "import { test, expect } from 'vitest';\ntest('broken', () => expect(1).toBe(2));\n",
  });
  const out = join(await mkdtemp(join(tmpdir(), 'vibing-mcp-report-')), 'report.json');
  try {
    const result = runGate({ dir, args: ['--reporter=json', `--outputFile=${out}`] });
    assert.notEqual(result.status, 0, 'a failing vitest test did not fail the gate');

    // **A non-zero exit is not on its own evidence that vitest ran.** The "dependencies are not
    // installed" branch that (d) covers exits non-zero too, and a scratch tree gets a *dangling*
    // node_modules symlink whenever the real one has not been installed -- so in a fresh worktree
    // this test used to pass green without vitest ever starting, which is the same shape of
    // vacuous gate the whole file is about. Read what ran, not only the code it exited with.
    const report = await readReport(out, result);
    assert.deepEqual(
      collectedNames(report),
      ['broken.test.ts', 'ok.test.ts'],
      'vitest did not run the two scratch files, so the non-zero exit above came from somewhere else'
    );
    assert.equal(report.numFailedTests, 1, 'the failing scratch test is not what failed the gate');
    assert.equal(report.numPassedTests, 1, 'the passing scratch test did not run');
  } finally {
    await rm(dir, { recursive: true, force: true });
    await rm(dirname(out), { recursive: true, force: true });
  }
});

test('(d) missing dependencies fail, and the message names the command that fixes it', async () => {
  const dir = await scratchServer(null);
  try {
    const result = runGate({ dir });
    assert.notEqual(result.status, 0, 'the gate reported success with no vitest installed');
    // The repository creates a worktree per issue, so this is the common case rather than an
    // exotic one, and the correct command is not guessable: a plain `pnpm install` in that
    // directory exits 0 and installs nothing.
    assert.match(result.stderr, /--ignore-workspace/);
    assert.match(result.stderr, /claude-plugin\/mcp-server/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('(e) the gate collects test files, and enough of them to be the suite', async () => {
  const out = join(await mkdtemp(join(tmpdir(), 'vibing-mcp-report-')), 'report.json');
  try {
    // Deliberately not asserting on the exit code: whether the suite passes is the gate's job,
    // and a red suite must not also be reported here as "the gate collects nothing". The result
    // is still kept, because `readReport` needs something to quote when there is no report.
    const result = runGate({ args: ['--reporter=json', `--outputFile=${out}`] });

    const report = await readReport(out, result);
    assert.ok(
      collectedFiles(report).length > 0,
      'the gate ran and collected no test files at all -- a green run that asserts nothing, ' +
        'which is the #790 state wearing a passing exit code'
    );
    // A lower bound rather than the exact count, so adding a test does not have to touch this
    // file. It is far enough above zero that a collapsed `include` cannot hide under it.
    assert.ok(
      report.numTotalTests >= 100,
      `expected the MCP server suite, got ${report.numTotalTests} tests`
    );
  } finally {
    await rm(dirname(out), { recursive: true, force: true });
  }
});

test('(f) the include glob narrows the directory, not the filename', async () => {
  // (e)'s lower bound catches an `include` that collapses to nothing. It cannot catch one that
  // collects most of the suite: every file this repository has today happens to be named
  // `*.test.ts`, so pinning `include` to that spelling looks correct and silently drops the first
  // `*.spec.ts` anyone writes -- collected by nothing, reported by nothing, counted in no total.
  // Both names are vitest's own default for TypeScript; only the directory is ours to narrow.
  const dir = await scratchServer({
    'alpha.test.ts':
      "import { test, expect } from 'vitest';\ntest('a', () => expect(1).toBe(1));\n",
    'beta.spec.ts': "import { test, expect } from 'vitest';\ntest('b', () => expect(1).toBe(1));\n",
  });
  const out = join(await mkdtemp(join(tmpdir(), 'vibing-mcp-report-')), 'report.json');
  try {
    const result = runGate({ dir, args: ['--reporter=json', `--outputFile=${out}`] });
    assert.deepEqual(
      collectedNames(await readReport(out, result)),
      ['alpha.test.ts', 'beta.spec.ts'],
      'a source test file was not collected -- widen vitest.config.mjs `include` rather than ' +
        'renaming the file, or the next one is dropped in silence too'
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
    await rm(dirname(out), { recursive: true, force: true });
  }
});
