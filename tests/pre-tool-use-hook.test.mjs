#!/usr/bin/env node
/**
 * The hook script is the half of the permission contract that talks to the CLI, and the CLI reads
 * it entirely through the exit code and stdout. Exiting 0 in silence is not an approval — it means
 * "no opinion", and the gate it falls through to cannot prompt anyone in headless `-p` mode, so
 * vibing-nvim's own MCP tools were refused under acceptEdits (issue #564).
 *
 * These tests stand in for the Neovim RPC server: a TCP listener that writes the .res file the
 * handler would write, so the real script runs its real polling path.
 */

import { strict as assert } from 'assert';
import { test } from 'node:test';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { mkdtemp, rm, writeFile } from 'fs/promises';
import { dirname, join } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const HOOK = join(repoRoot, 'bin/hooks/pre-tool-use.sh');

/**
 * Run the hook against a fake RPC server that answers with `hookOutput`.
 * @param {object} hookOutput value for hookSpecificOutput in the .res file
 */
async function runHook(hookOutput) {
  const commDir = await mkdtemp(join(tmpdir(), 'vibing-hook-test-'));
  const server = createServer((socket) => {
    socket.on('data', async (buf) => {
      const requestId = JSON.parse(buf.toString()).params.request_id;
      await writeFile(
        join(commDir, `${requestId}.res`),
        JSON.stringify({ hookSpecificOutput: hookOutput })
      );
      socket.end();
    });
  });

  try {
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));

    const child = spawn(HOOK, {
      env: {
        ...process.env,
        VIBING_NVIM_RPC_PORT: String(server.address().port),
        VIBING_HOOK_COMM_DIR: commDir,
      },
    });
    child.stdin.end(JSON.stringify({ tool_name: 'Read', tool_input: { file_path: '/tmp/x' } }));

    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (c) => (stdout += c));
    child.stderr.on('data', (c) => (stderr += c));
    const code = await new Promise((resolve) => child.on('close', resolve));

    return { code, stdout, stderr };
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(commDir, { recursive: true, force: true });
  }
}

test('allow is forwarded to the CLI verbatim, not swallowed', async () => {
  const output = {
    hookEventName: 'PreToolUse',
    permissionDecision: 'allow',
    permissionDecisionReason: 'allowed by vibing.nvim',
  };
  const { code, stdout } = await runHook(output);

  assert.equal(code, 0);
  assert.deepEqual(
    JSON.parse(stdout),
    { hookSpecificOutput: output },
    'a silent exit 0 is not a grant — the decision has to reach the CLI on stdout'
  );
});

test('defer exits 0 without claiming a decision', async () => {
  const { code, stdout } = await runHook({
    hookEventName: 'PreToolUse',
    permissionDecision: 'defer',
  });

  assert.equal(code, 0);
  assert.equal(stdout, '', 'defer must leave the CLI’s own permission flow in charge');
});

test('deny blocks with the reason on stderr', async () => {
  const { code, stderr } = await runHook({
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason: 'Cannot modify sensitive files',
  });

  assert.equal(code, 2);
  assert.match(stderr, /Cannot modify sensitive files/);
});
