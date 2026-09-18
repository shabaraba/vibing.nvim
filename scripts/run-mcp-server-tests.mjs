#!/usr/bin/env node
/**
 * Runs claude-plugin/mcp-server's vitest suite as part of `npm test` (#790).
 *
 * The suite sat outside every gate for its whole life: `test:node` sweeps the repository root's
 * `tests/` for `*.test.mjs` only, and CI checked that the mcp-server *directory* existed without
 * ever installing it or running anything in it.
 *
 * This is a script rather than a line in package.json because the two package managers are not
 * interchangeable here. CI installs with `npm ci`; local development uses pnpm. Spawning the
 * locally installed vitest binary directly commits to neither, and -- the point of the exercise --
 * lets the "dependencies are not installed" case exit non-zero with the exact command to fix it,
 * instead of an unreadable module-resolution stack or, worse, a silent skip. A gate that skips
 * itself is the state this issue records.
 *
 * Arguments are forwarded to vitest. `VIBING_MCP_SERVER_DIR` points the run at another directory
 * and exists for tests/mcp-server-test-gate.test.mjs, which has to drive this script against trees
 * it builds itself.
 */

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const serverDir = process.env.VIBING_MCP_SERVER_DIR
  ? resolve(process.env.VIBING_MCP_SERVER_DIR)
  : join(repoRoot, 'claude-plugin', 'mcp-server');

const vitest = join(serverDir, 'node_modules', '.bin', 'vitest');

if (!existsSync(vitest)) {
  // The suite also imports `zod`, which only the repository root declares, so name both trees
  // when both are missing -- installing one and re-running to find the other is the same walk
  // twice.
  const rootMissing = !existsSync(join(repoRoot, 'node_modules'));
  process.stderr.write(
    [
      `MCP server tests cannot run: ${vitest} does not exist.`,
      '',
      'Install the dependencies and re-run. With pnpm, from the repository root:',
      '',
      ...(rootMissing ? ['    pnpm install'] : []),
      '    pnpm install --ignore-workspace --dir claude-plugin/mcp-server',
      '',
      '--ignore-workspace is required. claude-plugin/mcp-server has its own package.json but is',
      'not a member of the root pnpm-workspace.yaml, so a plain `pnpm install` there exits 0 and',
      'installs nothing. With npm the equivalent is `npm ci` in each directory; ./build.sh already',
      'installs both as part of a normal build.',
      '',
    ].join('\n')
  );
  process.exit(1);
}

const result = spawnSync(vitest, ['run', ...process.argv.slice(2)], {
  cwd: serverDir,
  stdio: 'inherit',
});

if (result.error) {
  process.stderr.write(`MCP server tests could not be started: ${result.error.message}\n`);
  process.exit(1);
}

// A null status means a signal killed vitest; report that as a failure rather than as the 0 an
// `exit(result.status)` would produce.
process.exit(result.status ?? 1);
