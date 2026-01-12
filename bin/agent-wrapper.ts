/**
 * Claude Agent SDK wrapper for vibing.nvim
 * Uses query API for full permission control support
 * Outputs streaming text chunks to stdout as JSON lines
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import { parseArguments } from './lib/args-parser.js';
import { buildPrompt } from './lib/prompt-builder.js';
import { createCanUseToolCallback } from './lib/permissions/can-use-tool.js';
import { processStream } from './lib/stream-processor.js';
import { safeJsonStringify, toError } from './lib/utils.js';

const args = process.argv.slice(2);
const config = parseArguments(args);

const fullPrompt = buildPrompt(config);

// Change process working directory to match the requested cwd
// This ensures all shell commands and file operations use the correct directory
if (config.cwd) {
  process.chdir(config.cwd);
}

const queryOptions: Record<string, unknown> = {
  cwd: config.cwd,
  allowDangerouslySkipPermissions: config.permissionMode === 'bypassPermissions',
  settingSources: ['user', 'project'],
};

if (config.deniedTools.length > 0) {
  queryOptions.disallowedTools = config.deniedTools;
}

if (config.allowedTools.length > 0) {
  queryOptions.allowedTools = config.allowedTools;
}

queryOptions.canUseTool = createCanUseToolCallback(config);

if (config.mode) {
  queryOptions.mode = config.mode;
}

if (config.model) {
  queryOptions.model = config.model;
}

if (config.sessionId) {
  queryOptions.resume = config.sessionId;
}

try {
  const result = query({
    prompt: fullPrompt,
    options: queryOptions,
  });

  await processStream(result, config.toolResultDisplay, config.sessionId, config.cwd, config);
} catch (error) {
  const err = toError(error);
  console.log(safeJsonStringify({ type: 'error', message: err.message }));
  process.exit(1);
}
