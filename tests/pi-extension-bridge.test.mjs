// The Pi permission bridge (`pi-extension/`), exercised as Pi calls it.
//
// This is the only automated coverage of the one backend whose permission gate has nothing
// underneath it. Every other backend's CLI refuses an unapproved tool on its own; Pi does not ask
// at all, so if this handler returns the wrong thing the user's `permissions.deny` rules and the
// bundled destructive-command rules simply do not apply, silently.
//
// No model and no `pi` binary are involved: the handler is called directly with a `tool_call` event
// of the shape Pi emits (captured from Pi 0.87.1), against a stand-in for vibing.nvim's RPC server.
// So this runs anywhere `bin/hooks/pre-tool-use.sh` can run.
import assert from 'node:assert/strict';
import test, { before, after } from 'node:test';
import { createServer } from 'node:net';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const BUNDLE = join(REPO_ROOT, 'pi-extension', 'dist', 'index.js');
const HOOK_SCRIPT = join(REPO_ROOT, 'bin', 'hooks', 'pre-tool-use.sh');

/** What Pi 0.87.1 hands a `tool_call` handler. */
const TOOL_CALL = {
  type: 'tool_call',
  toolCallId: 'tc-1',
  toolName: 'bash',
  input: { command: 'rm -rf /' },
};

let server;
let port;
let commDir;
let handler;
/** What the stand-in should answer with next: "deny" | "allow" | "defer". */
let decision = 'defer';
/** Every payload the bridge wrote, so the shape the Lua vocabulary reads can be asserted. */
const payloads = [];

/** The bundle is git-ignored, exactly as the MCP server's dist/ is, and CI does not run build.sh. */
function buildBundle() {
  // The root's typescript, because pi-extension declares no dependencies of its own.
  execFileSync(join(REPO_ROOT, 'node_modules', '.bin', 'tsc'), ['-p', 'pi-extension'], {
    cwd: REPO_ROOT,
    stdio: 'pipe',
  });
}

before(async () => {
  buildBundle();

  commDir = mkdtempSync(join(tmpdir(), 'vibing-pi-bridge-'));
  mkdirSync(commDir, { recursive: true });

  server = createServer((socket) => {
    let buffer = '';
    socket.on('data', (chunk) => {
      buffer += chunk.toString();
      const match = buffer.match(/"request_id":"([^"]+)"/);
      if (!match) return;
      const id = match[1];
      payloads.push(JSON.parse(readFileSync(join(commDir, `${id}.req`), 'utf8')));
      const body =
        decision === 'deny'
          ? {
              // Quote-free on purpose. The shared script's exit-2 path recovers the reason with
              // `grep -o '"permissionDecisionReason":"[^"]*"' | cut`, which stops at the first
              // escaped quote inside the value -- so a reason containing `"` arrives truncated on
              // every backend that reads stderr, not just this one. That is a defect in
              // bin/hooks/pre-tool-use.sh and not in this bridge, and asserting the truncated form
              // here would pin the bug in place.
              permissionDecision: 'deny',
              permissionDecisionReason: 'Bash(rm -rf /) is denied by permissions.deny',
            }
          : decision === 'allow'
            ? { permissionDecision: 'allow' }
            : { permissionDecision: 'defer' };
      writeFileSync(join(commDir, `${id}.res`), JSON.stringify({ hookSpecificOutput: body }));
      socket.end();
    });
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  port = server.address().port;

  const registered = {};
  const factory = (await import(BUNDLE)).default;
  factory({ on: (event, fn) => (registered[event] = fn) });
  handler = registered.tool_call;

  process.env.VIBING_NVIM_RPC_PORT = String(port);
  process.env.VIBING_HOOK_COMM_DIR = commDir;
  process.env.VIBING_HOOK_MAX_WAIT_SEC = '15';
  process.env.VIBING_PROCESS_ID = 'bridgetest';
  process.env.VIBING_PI_HOOK_SCRIPT = HOOK_SCRIPT;
  process.env.VIBING_PI_HOOK_TIMEOUT_SEC = '30';
});

after(() => {
  server?.close();
  rmSync(commDir, { recursive: true, force: true });
});

/** @returns {Promise<{block?: boolean, reason?: string} | undefined>} */
function ask(ctx = { hasUI: false, cwd: '/tmp' }) {
  return handler(TOOL_CALL, ctx);
}

test('it registers a tool_call handler, which is the only interception point Pi offers', () => {
  assert.equal(typeof handler, 'function');
});

test("a deny reaches Pi as a block carrying the rule's own message", async () => {
  // The reason is the only path a deny rule's `message` takes to the model. Blocking without it
  // tells the model it was refused and nothing about why, so it retries the same call.
  decision = 'deny';
  const verdict = await ask();
  assert.equal(verdict?.block, true);
  assert.match(verdict.reason, /denied by permissions\.deny/);
});

test('an allow lets the tool run', async () => {
  // Returning anything truthy for `block` here would refuse a call vibing.nvim approved.
  decision = 'allow';
  assert.equal(await ask(), undefined);
});

test('a defer lets the tool run, because Pi has no gate to defer to', async () => {
  // On every other backend "no opinion" hands the decision to the CLI's own gate. Pi has none, so
  // defer and allow are the same act — and treating defer as a refusal would block every tool call
  // vibing.nvim merely had no rule about.
  decision = 'defer';
  assert.equal(await ask(), undefined);
});

test("it sends Pi's own field names, which is what pi_tool_vocabulary translates", async () => {
  // `toolName` and `input` -- not grok's `toolInput`. If this shape changes, the Lua side reads a
  // nil tool name, every granular rule misses, and the vocabulary silently does nothing.
  decision = 'allow';
  payloads.length = 0;
  await ask({ hasUI: false, cwd: '/tmp/work' });

  assert.equal(payloads.length, 1);
  assert.deepEqual(payloads[0], {
    hookEventName: 'PreToolUse',
    toolName: 'bash',
    input: { command: 'rm -rf /' },
    toolCallId: 'tc-1',
    cwd: '/tmp/work',
  });
});

test('it leaves no request or response file behind', async () => {
  decision = 'allow';
  await ask();
  assert.deepEqual(readdirSync(commDir), []);
});

test('it fails closed when the RPC server cannot be reached', async () => {
  // The security property. An unreachable Neovim must not read as permission: nothing looked at
  // the call, and on this backend nothing else will.
  const original = process.env.VIBING_NVIM_RPC_PORT;
  process.env.VIBING_NVIM_RPC_PORT = '1';
  try {
    const verdict = await ask();
    assert.equal(verdict?.block, true);
    assert.match(verdict.reason, /Failed to connect/);
  } finally {
    process.env.VIBING_NVIM_RPC_PORT = original;
  }
});

test('it blocks when the bridge is configured but its script path is missing', async () => {
  // A broken install, which must not be indistinguishable from an approval.
  const original = process.env.VIBING_PI_HOOK_SCRIPT;
  delete process.env.VIBING_PI_HOOK_SCRIPT;
  try {
    const verdict = await ask();
    assert.equal(verdict?.block, true);
    assert.match(verdict.reason, /VIBING_PI_HOOK_SCRIPT unset/);
  } finally {
    process.env.VIBING_PI_HOOK_SCRIPT = original;
  }
});

test('it defers entirely when Pi was not started by vibing.nvim', async () => {
  // The extension can be installed into a user's own Pi. Without an RPC port there is nothing to
  // ask, and refusing every tool call would break a plain `pi` session that loaded it. The shared
  // script makes the same judgement from the same variable.
  const original = process.env.VIBING_NVIM_RPC_PORT;
  delete process.env.VIBING_NVIM_RPC_PORT;
  try {
    assert.equal(await ask(), undefined);
  } finally {
    process.env.VIBING_NVIM_RPC_PORT = original;
  }
});
