#!/usr/bin/env node
/**
 * CI's "Audit every committed lockfile" step is `npm run audit:deps`, and it reads nothing but the
 * exit code.
 *
 * The failure it exists to prevent is not "a vulnerable package is installed" -- it is "a package
 * tree nobody looks at" (#691). The repository has two independent npm trees, and for the whole
 * time claude-plugin/mcp-server carried four high advisories, every path that could have printed
 * them ran under `--silent`. So the property under test is coverage: the gate audits *every*
 * committed package-lock.json, fails when any one of them reports, and fails rather than passes
 * when it finds none.
 *
 * These tests run the real script against a throwaway git tree with a fake `npm` first on PATH, so
 * they assert on the argv it actually passes -- no registry, and no dependence on which advisories
 * happen to be open today.
 */

import { strict as assert } from 'assert';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, chmod, rm, readFile } from 'fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const script = join(repoRoot, 'scripts/audit-dependencies.mjs');

/**
 * A stand-in for npm that records the directory it was run in, and fails in whichever directories
 * $FAILING_DIRS names -- which is how a report from one tree among several is simulated.
 */
const FAKE_NPM = `#!/bin/sh
printf '%s\\t%s\\n' "$PWD" "$*" >> "$NPM_LOG"
for failing in $FAILING_DIRS; do
  case "$PWD" in
    */"$failing") exit 1 ;;
  esac
done
exit 0
`;

/** Run the audit script over a throwaway git repo containing `lockfileDirs`, with npm faked out. */
async function runAudit(lockfileDirs, { failingDirs = [] } = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'vibing-audit-'));
  try {
    const binDir = join(dir, 'fakebin');
    await mkdir(binDir, { recursive: true });
    await writeFile(join(binDir, 'npm'), FAKE_NPM);
    await chmod(join(binDir, 'npm'), 0o755);

    const tree = join(dir, 'repo');
    await mkdir(tree, { recursive: true });
    for (const relative of lockfileDirs) {
      await mkdir(join(tree, relative), { recursive: true });
      await writeFile(join(tree, relative, 'package-lock.json'), '{}\n');
    }

    for (const argv of [
      ['init', '-q'],
      ['add', '-A'],
    ]) {
      const git = spawnSync('git', argv, { cwd: tree, encoding: 'utf8' });
      assert.equal(git.status, 0, `git ${argv.join(' ')} failed: ${git.stderr}`);
    }

    const log = join(dir, 'npm.log');
    const result = spawnSync(process.execPath, [script, tree], {
      encoding: 'utf8',
      timeout: 60_000,
      env: {
        ...process.env,
        PATH: `${binDir}:${process.env.PATH}`,
        NPM_LOG: log,
        FAILING_DIRS: failingDirs.join(' '),
      },
    });
    assert.notEqual(result.status, null, `the script did not exit: ${result.error ?? 'unknown'}`);

    const calls = existsSync(log)
      ? readFileSync(log, 'utf8')
          .split('\n')
          .filter(Boolean)
          .map((line) => {
            const [cwd, argv] = line.split('\t');
            return { cwd, argv };
          })
      : [];
    return { status: result.status, stdout: result.stdout, stderr: result.stderr, calls };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test('every committed lockfile is audited, not just the root one', async () => {
  const { status, calls } = await runAudit(['.', 'claude-plugin/mcp-server']);
  assert.equal(status, 0);
  assert.equal(calls.length, 2, `expected one npm run per tree, got ${JSON.stringify(calls)}`);
  assert.ok(
    calls.some(({ cwd }) => cwd.endsWith('/mcp-server')),
    'the nested tree was never audited -- this is the #691 shape, one directory short'
  );
});

test('a tree npm reports on fails the run even when the others are clean', async () => {
  const { status } = await runAudit(['.', 'claude-plugin/mcp-server'], {
    failingDirs: ['mcp-server'],
  });
  assert.notEqual(status, 0, 'npm audit reported but the gate exited 0');
});

test('a report in the first tree is not cleared by a clean later one', async () => {
  // The loop keeps going after a failure so every tree gets reported in one run, which is why the
  // status has to accumulate; exiting with the last npm's code would lose this case entirely.
  const { status, calls } = await runAudit(['.', 'claude-plugin/mcp-server'], {
    failingDirs: ['repo'],
  });
  assert.notEqual(status, 0);
  assert.equal(calls.length, 2, 'the run stopped at the first failure instead of auditing both');
});

test('a tree with no committed lockfile fails rather than reporting success', async () => {
  const { status, calls } = await runAudit([]);
  assert.notEqual(status, 0, 'an audit that examined nothing reported success');
  assert.equal(calls.length, 0);
});

test('the audit runs at a level that can fail', async () => {
  const { calls } = await runAudit(['.']);
  const [{ argv }] = calls;
  assert.match(argv, /(^| )audit( |$)/);
  const level = argv.match(/--audit-level=(\w+)/)?.[1];
  assert.ok(
    level && ['low', 'moderate', 'high', 'critical'].includes(level),
    `--audit-level is ${level ?? 'absent'}; "none" or a missing level is a gate that cannot fail`
  );
});

test('CI runs the script rather than its own copy of the directory list', async () => {
  const ci = await readFile(join(repoRoot, '.github/workflows/ci.yml'), 'utf8');
  const auditScript = JSON.parse(await readFile(join(repoRoot, 'package.json'), 'utf8')).scripts[
    'audit:deps'
  ];
  assert.ok(auditScript, 'package.json has no audit:deps script for CI to run');
  assert.match(ci, /run: npm run audit:deps/, 'no CI step runs the dependency audit');
  assert.doesNotMatch(
    ci.slice(ci.indexOf('  audit:')),
    /continue-on-error/,
    'the audit job is allowed to fail, which makes it a report rather than a gate'
  );
});

test('every committed lockfile has a Dependabot entry', async () => {
  // Dependabot cannot discover trees the way the script does -- each package.json /
  // package-lock.json pair needs its own `directory`. A tree that is audited but not updated
  // goes red on the next advisory with nothing opening a pull request to clear it.
  const listed = spawnSync('git', ['ls-files', '--', '*package-lock.json'], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
  assert.equal(listed.status, 0, `git ls-files failed: ${listed.stderr}`);

  const dirs = listed.stdout
    .split('\n')
    .filter((line) => line.endsWith('package-lock.json'))
    .map((line) => (dirname(line) === '.' ? '/' : `/${dirname(line)}`));
  assert.ok(dirs.length > 0, 'no committed lockfile found; the check below would assert nothing');

  const dependabot = await readFile(join(repoRoot, '.github/dependabot.yml'), 'utf8');
  const registered = [...dependabot.matchAll(/^\s*directory:\s*(\S+)\s*$/gm)].map(([, d]) =>
    d.replace(/^['"]|['"]$/g, '')
  );
  for (const dir of dirs) {
    assert.ok(
      registered.includes(dir),
      `${dir} has a committed lockfile but no dependabot.yml entry (found: ${registered.join(', ')})`
    );
  }
});
