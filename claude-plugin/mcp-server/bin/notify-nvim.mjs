/**
 * Tell the Neovim that launched this session why the MCP server is slow, or missing.
 *
 * The launcher runs inside Claude Code's 30s MCP startup deadline, and until now anything it had
 * to say about overrunning it went nowhere. Measured against claude 2.1.231 with a stand-in
 * plugin whose server only writes one line to stderr and sleeps: that line reaches neither the
 * CLI's stdout nor its stderr. It is captured into
 * `~/Library/Caches/claude-cli-nodejs/<cwd-slug>/mcp-logs-plugin-<plugin>-<server>/*.jsonl`, and
 * even there it is buffered -- it appears only when the connection times out, 30s later, next to
 * `Connection timeout triggered after 30002ms (limit: 30000ms)`.
 *
 * So `console.error` is not a channel to the user; vibing.nvim's own RPC server is. Both CLI
 * adapters export `VIBING_NVIM_RPC_PORT` (`adapter/modules/rpc_environment.lua`) and claude hands
 * the launching environment to plugin MCP servers, so it is already in this process's env. The
 * server speaks newline-delimited JSON-RPC on 127.0.0.1; `notify` is a one-line handler on it.
 *
 * Delivery has to happen in a *separate* process, which is why this file is both a module and a
 * script. Its callers are about to block their own event loop in `spawnSync('npm', ...)` for as
 * long as the build takes, and a socket opened just before that would not connect until the build
 * finished -- which, in the case worth reporting, is after Claude Code has already killed them.
 * `spawn()` creates the child before it returns, so the detached copy delivers while the parent
 * is blocked.
 */
import * as net from 'node:net';
import { spawn } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const RPC_PORT_ENV = 'VIBING_NVIM_RPC_PORT';

/** Short: a notification nobody is listening for must not outlive the thing it describes. */
const DELIVERY_TIMEOUT_MS = 3000;

const selfPath = fileURLToPath(import.meta.url);

/**
 * Connect, write one request, leave. Runs in the detached child, whose event loop is free.
 * @param {string} level one of "info", "warn", "error"
 * @param {string} message
 */
function deliver(level, message) {
  const port = Number.parseInt(process.env[RPC_PORT_ENV] ?? '', 10);
  if (!Number.isInteger(port) || port <= 0) return;

  const socket = net.connect({ host: '127.0.0.1', port });
  socket.setTimeout(DELIVERY_TIMEOUT_MS, () => socket.destroy());
  // Neovim being gone is the normal case for a launcher started outside vibing.nvim, not a
  // failure: nothing here is worth an exit code.
  socket.on('error', () => {});
  socket.on('connect', () => {
    socket.end(
      JSON.stringify({
        id: 1,
        method: 'notify',
        params: { level, message, title: 'MCP Server' },
      }) + '\n'
    );
  });
}

/**
 * Ask a detached copy of this file to deliver `message`. Returns immediately and never throws.
 * @param {string} level one of "info", "warn", "error"
 * @param {string} message
 */
export function notifyNvim(level, message) {
  if (!process.env[RPC_PORT_ENV]) return;
  try {
    spawn(process.execPath, [selfPath, level, message], {
      detached: true,
      stdio: 'ignore',
    }).unref();
  } catch {
    // A notification is never worth failing the launch for.
  }
}

// Script mode. `process.argv[1]` is compared through realpath because the launcher may be reached
// through a symlinked plugin directory, in which case the two spellings differ.
if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(selfPath)) {
  deliver(process.argv[2], process.argv.slice(3).join(' '));
}
