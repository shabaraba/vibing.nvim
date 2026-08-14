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
 * @param {string[]} args argv for the hook (selects the CLI's decision format)
 */
async function runHook(hookOutput, args = []) {
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

    const child = spawn(HOOK, args, {
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

/*
 * Copilot reads the same decisions differently, verified against copilot 1.0.78: it parses a FLAT
 * object and ignores Claude's hookSpecificOutput wrapper (a nested deny ran the tool anyway), and
 * it drops stderr on exit 2 (the model was told only "hook exited with code 2").
 */

test('copilot deny is a flat object on stdout, carrying the reason', async () => {
  const { code, stdout } = await runHook(
    {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: 'Cannot modify sensitive files',
    },
    ['copilot']
  );

  const decision = JSON.parse(stdout);
  assert.equal(decision.permissionDecision, 'deny');
  assert.equal(decision.permissionDecisionReason, 'Cannot modify sensitive files');
  assert.equal(code, 0, 'exit 2 also denies, but replaces the reason with a generic message');
});

test('copilot deny stays parsable when the reason contains quotes', async () => {
  // The flat object is produced by unwrapping the response, not by re-encoding the fields:
  // rebuilding it from a grep/cut of the JSON truncates at the escaped quote and emits a
  // trailing backslash, and copilot reads output it cannot parse as "no decision" — i.e. allow.
  const reason = 'Refused: "rm -rf /" is a \\ destructive command';
  const { stdout } = await runHook(
    { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
    ['copilot']
  );

  assert.equal(JSON.parse(stdout).permissionDecisionReason, reason);
});

test('copilot allow is a flat object too', async () => {
  const { code, stdout } = await runHook(
    { hookEventName: 'PreToolUse', permissionDecision: 'allow' },
    ['copilot']
  );

  assert.equal(code, 0);
  assert.equal(JSON.parse(stdout).permissionDecision, 'allow');
});

test('copilot defer still exits 0 in silence', async () => {
  const { code, stdout } = await runHook(
    { hookEventName: 'PreToolUse', permissionDecision: 'defer' },
    ['copilot']
  );

  assert.equal(code, 0);
  assert.equal(stdout, '');
});

test('copilot deny falls back to exit 2 when the response cannot be unwrapped', async () => {
  // The unwrap anchors on the exact shape write_hook_response() emits. If that ever grows a
  // top-level sibling key, the strip stops matching — and printing the untouched nested object
  // would read as "no decision" on copilot, i.e. the denied tool runs. Deny fails closed instead.
  const commDir = await mkdtemp(join(tmpdir(), 'vibing-hook-test-'));
  const server = createServer((socket) => {
    socket.on('data', async (buf) => {
      const requestId = JSON.parse(buf.toString()).params.request_id;
      await writeFile(
        join(commDir, `${requestId}.res`),
        JSON.stringify({
          continue: false,
          hookSpecificOutput: { permissionDecision: 'deny', permissionDecisionReason: 'nope' },
        })
      );
      socket.end();
    });
  });

  try {
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const child = spawn(HOOK, ['copilot'], {
      env: {
        ...process.env,
        VIBING_NVIM_RPC_PORT: String(server.address().port),
        VIBING_HOOK_COMM_DIR: commDir,
      },
    });
    child.stdin.end(JSON.stringify({ toolName: 'bash', toolArgs: '{"command":"ls"}' }));

    let stdout = '';
    child.stdout.on('data', (c) => (stdout += c));
    const code = await new Promise((resolve) => child.on('close', resolve));

    assert.equal(code, 2, 'an unrecognised response shape must still deny');
    assert.equal(stdout, '', 'and must not print an object copilot would ignore');
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(commDir, { recursive: true, force: true });
  }
});

test('copilot fails closed when the RPC server is unreachable', async () => {
  // Non-zero exits deny on copilot as well; only a hook that outlives timeoutSec fails open,
  // which is why the generated hooks.json allows more time than this script waits.
  const child = spawn(HOOK, ['copilot'], {
    env: { ...process.env, VIBING_NVIM_RPC_PORT: '1', VIBING_HOOK_COMM_DIR: tmpdir() },
  });
  child.stdin.end(JSON.stringify({ toolName: 'bash', toolArgs: '{"command":"ls"}' }));
  const code = await new Promise((resolve) => child.on('close', resolve));

  assert.equal(code, 2);
});
