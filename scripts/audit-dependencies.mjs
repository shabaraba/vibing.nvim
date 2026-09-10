#!/usr/bin/env node
/**
 * Audit every package-lock.json this repository commits.
 *
 * Usage:
 *   node scripts/audit-dependencies.mjs [repo-root]
 *
 * The repository has two independent npm trees -- the root one and claude-plugin/mcp-server/ --
 * and until #691 nothing looked at either. `npm audit` runs on request only, and both build paths
 * pass `--silent`, which suppresses the summary npm prints after an install; the seven advisories
 * open at the time had therefore never been shown to anyone.
 *
 * The set of directories is discovered with `git ls-files` rather than listed here or in ci.yml,
 * because the failure this guards against is a *third* tree being added and quietly skipped. A run
 * that finds no lockfile at all is a failure for the same reason -- a gate that audits nothing
 * reports success.
 *
 * The repo-root argument exists so tests/dependency-audit-gate.test.mjs can point it at a
 * throwaway tree; a gate nothing can fail is not a gate.
 */

import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';

// `npm audit` exits non-zero as soon as one advisory at or above this level is found. `high` is
// where the threshold starts rather than ends: moderate advisories land in transitive dev
// dependencies often enough that a moderate gate would spend most of its life red on unrelated
// pull requests, and a gate people route around is the state this whole script exists to leave.
// Dependabot (.github/dependabot.yml) is what surfaces everything below the line.
const AUDIT_LEVEL = 'high';

const repoRoot = process.argv[2] ?? process.cwd();

/** Every committed package-lock.json, as the directory npm has to be run in. */
function lockfileDirs() {
  const listed = spawnSync('git', ['ls-files', '--', '*package-lock.json'], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
  if (listed.status !== 0) {
    const reason = listed.error?.message ?? listed.stderr?.trim() ?? 'unknown error';
    console.error(`[audit] could not list files under ${repoRoot}: ${reason}`);
    process.exit(1);
  }

  return listed.stdout
    .split('\n')
    .filter((line) => line.endsWith('package-lock.json'))
    .filter((line) => !line.includes('node_modules/'))
    .map((line) => dirname(line))
    .sort();
}

const dirs = lockfileDirs();
if (dirs.length === 0) {
  console.error(`[audit] no committed package-lock.json found under ${repoRoot}`);
  process.exit(1);
}

const failed = [];
for (const dir of dirs) {
  const label = dir === '.' ? '(repository root)' : dir;
  console.log(`[audit] ${label}`);

  // No `npm ci` first: `npm audit` resolves the advisories from the lockfile, so the gate costs
  // one registry round trip per tree and needs no node_modules.
  const audit = spawnSync('npm', ['audit', `--audit-level=${AUDIT_LEVEL}`], {
    cwd: join(repoRoot, dir),
    stdio: 'inherit',
  });
  if (audit.error) {
    console.error(`[audit] could not run npm in ${label}: ${audit.error.message}`);
    failed.push(label);
  } else if (audit.status !== 0) {
    failed.push(label);
  }
}

if (failed.length > 0) {
  console.error(
    `[audit] ${failed.join(', ')} report advisories at ${AUDIT_LEVEL} or above. ` +
      'Update the dependency and commit the refreshed lockfile.'
  );
  process.exit(1);
}

console.log(`[audit] ${dirs.length} lockfile(s) clean at ${AUDIT_LEVEL} or above`);
