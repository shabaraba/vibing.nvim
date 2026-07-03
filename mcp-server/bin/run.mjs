#!/usr/bin/env node
/**
 * Self-building launcher for the vibing-nvim MCP server.
 *
 * Claude Code plugin installation does not run an install/build step, so
 * this wrapper builds mcp-server/dist on first launch (if missing) before
 * exec'ing the compiled server. Used as the `command` for the plugin's
 * bundled MCP server in .claude-plugin/plugin.json.
 */
import { existsSync } from 'node:fs';
import { spawnSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const mcpDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const distEntry = join(mcpDir, 'dist', 'index.js');

function run(command, args) {
  const result = spawnSync(command, args, { cwd: mcpDir, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}

if (!existsSync(distEntry)) {
  console.error('[vibing-nvim] Building MCP server (first run)...');
  run('npm', ['install', '--silent']);
  run('npm', ['run', 'build', '--silent']);
}

const child = spawn(process.execPath, [distEntry], { stdio: 'inherit', env: process.env });
child.on('exit', (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 0);
});
