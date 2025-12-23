#!/usr/bin/env node
/**
 * Register vibing-nvim MCP server in ~/.claude.json
 * Called automatically by build.sh after successful build
 */

import { readFileSync, writeFileSync, existsSync, renameSync, mkdtempSync, unlinkSync } from 'fs';
import { join } from 'path';
import { fileURLToPath } from 'url';
import { dirname, resolve } from 'path';
import { homedir, tmpdir } from 'os';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const CLAUDE_JSON_PATH = join(homedir(), '.claude.json');
const PLUGIN_ROOT = resolve(__dirname, '..');
const MCP_SERVER_PATH = join(PLUGIN_ROOT, 'mcp-server', 'dist', 'index.js');

// Check if MCP server is built
if (!existsSync(MCP_SERVER_PATH)) {
  console.error('[vibing.nvim] Error: MCP server not built. dist/index.js not found.');
  process.exit(1);
}

// Read existing claude.json or create new
let config = {};
if (existsSync(CLAUDE_JSON_PATH)) {
  try {
    const content = readFileSync(CLAUDE_JSON_PATH, 'utf-8');
    config = JSON.parse(content);
  } catch (error) {
    console.error(`[vibing.nvim] Warning: Failed to parse ${CLAUDE_JSON_PATH}: ${error.message}`);
    console.error('[vibing.nvim] Creating new configuration...');
    config = {};
  }
} else {
  console.log('[vibing.nvim] Creating new ~/.claude.json...');
}

// Initialize mcpServers if not present
if (!config.mcpServers) {
  config.mcpServers = {};
}

// Check if vibing-nvim already configured
const existingConfig = config.mcpServers['vibing-nvim'];
if (existingConfig && existingConfig.args && existingConfig.args[0] === MCP_SERVER_PATH) {
  console.log('[vibing.nvim] ✓ vibing-nvim MCP server already registered in ~/.claude.json');
  process.exit(0);
} else if (existingConfig) {
  console.log('[vibing.nvim] Updating vibing-nvim registration (path changed)...');
}

// Register vibing-nvim MCP server
config.mcpServers['vibing-nvim'] = {
  command: 'node',
  args: [MCP_SERVER_PATH],
  env: {
    VIBING_RPC_PORT: '9876',
  },
};

// Write updated config atomically (temp file → rename)
let tempFile;
try {
  // Create temp directory and file
  const tempDir = mkdtempSync(join(tmpdir(), 'vibing-'));
  tempFile = join(tempDir, 'claude.json');

  // Write to temp file
  writeFileSync(tempFile, JSON.stringify(config, null, 2) + '\n', 'utf-8');

  // Atomic rename (prevents data loss on failure)
  renameSync(tempFile, CLAUDE_JSON_PATH);

  console.log('[vibing.nvim] ✓ Registered vibing-nvim MCP server in ~/.claude.json');
  console.log(`[vibing.nvim]   Path: ${MCP_SERVER_PATH}`);
  console.log('[vibing.nvim]   Port: 9876');
} catch (error) {
  // Clean up temp file if exists
  if (tempFile && existsSync(tempFile)) {
    try {
      unlinkSync(tempFile);
    } catch {
      // Ignore cleanup errors
    }
  }
  console.error(`[vibing.nvim] Error: Failed to write ${CLAUDE_JSON_PATH}: ${error.message}`);
  process.exit(1);
}
