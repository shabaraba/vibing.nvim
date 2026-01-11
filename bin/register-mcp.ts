/**
 * Register vibing-nvim MCP server in ~/.claude.json
 * Called automatically by build.sh after successful build
 */

import {
  readFileSync,
  writeFileSync,
  existsSync,
  renameSync,
  mkdtempSync,
  unlinkSync,
  rmSync,
} from 'fs';
import { join } from 'path';
import { fileURLToPath } from 'url';
import { dirname, resolve } from 'path';
import { homedir, tmpdir } from 'os';
import { toError } from './lib/utils.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const CLAUDE_JSON_PATH = join(homedir(), '.claude.json');
const PLUGIN_ROOT = resolve(__dirname, '../..');
const MCP_SERVER_PATH = join(PLUGIN_ROOT, 'mcp-server', 'dist', 'index.js');

// Check if MCP server is built
if (!existsSync(MCP_SERVER_PATH)) {
  console.error('[vibing.nvim] Error: MCP server not built. dist/index.js not found.');
  process.exit(1);
}

// Read existing claude.json or create new
let config: Record<string, unknown> = {};
if (existsSync(CLAUDE_JSON_PATH)) {
  try {
    const content = readFileSync(CLAUDE_JSON_PATH, 'utf-8');
    config = JSON.parse(content);
  } catch (error) {
    const err = toError(error);
    console.error(`[vibing.nvim] Warning: Failed to parse ${CLAUDE_JSON_PATH}: ${err.message}`);
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

const mcpServers = config.mcpServers as Record<string, unknown>;

// Check if vibing-nvim already configured
const existingConfig = mcpServers['vibing-nvim'] as Record<string, unknown> | undefined;
if (
  existingConfig &&
  Array.isArray(existingConfig.args) &&
  existingConfig.args[0] === MCP_SERVER_PATH &&
  existingConfig.type === 'stdio'
) {
  console.log('[vibing.nvim] ✓ vibing-nvim MCP server already registered in ~/.claude.json');
  process.exit(0);
} else if (existingConfig) {
  console.log('[vibing.nvim] Updating vibing-nvim registration (path or configuration changed)...');
}

// Register vibing-nvim MCP server
mcpServers['vibing-nvim'] = {
  command: 'node',
  args: [MCP_SERVER_PATH],
  env: {
    VIBING_RPC_PORT: '9876',
    VIBING_RPC_TIMEOUT: '30000', // 30 seconds (increased from 5s for heavy LSP operations)
  },
  type: 'stdio',
};

// Write updated config atomically (temp file → rename)
let tempFile: string | undefined;
let tempDir: string | undefined;
try {
  // Create temp directory and file
  tempDir = mkdtempSync(join(tmpdir(), 'vibing-'));
  tempFile = join(tempDir, 'claude.json');

  // Write to temp file
  writeFileSync(tempFile, JSON.stringify(config, null, 2) + '\n', 'utf-8');

  // Atomic rename (prevents data loss on failure)
  renameSync(tempFile, CLAUDE_JSON_PATH);

  // Clean up temp directory
  rmSync(tempDir, { recursive: true, force: true });

  console.log('[vibing.nvim] ✓ Registered vibing-nvim MCP server in ~/.claude.json');
  console.log(`[vibing.nvim]   Path: ${MCP_SERVER_PATH}`);
  console.log('[vibing.nvim]   Port: 9876');
  console.log('[vibing.nvim]   Timeout: 30000ms (30s)');
} catch (error) {
  const err = toError(error);
  // Clean up temp file and directory if they exist
  if (tempFile && existsSync(tempFile)) {
    try {
      unlinkSync(tempFile);
    } catch {
      // Ignore cleanup errors
    }
  }
  if (tempDir && existsSync(tempDir)) {
    try {
      rmSync(tempDir, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors
    }
  }
  console.error(`[vibing.nvim] Error: Failed to write ${CLAUDE_JSON_PATH}: ${err.message}`);
  process.exit(1);
}
