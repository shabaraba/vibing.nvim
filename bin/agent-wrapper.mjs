#!/usr/bin/env node
/**
 * Claude Agent SDK wrapper for vibing.nvim
 * Uses query API for full permission control support
 * Outputs streaming text chunks to stdout as JSON lines
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import { parseArguments } from './lib/args-parser.mjs';
import { buildPrompt } from './lib/prompt-builder.mjs';
import { createCanUseToolCallback } from './lib/permissions/can-use-tool.mjs';
import { processStream } from './lib/stream-processor.mjs';
import { safeJsonStringify } from './lib/utils.mjs';

const args = process.argv.slice(2);
const config = parseArguments(args);

const fullPrompt = buildPrompt(config);

const queryOptions = {
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
  console.log(safeJsonStringify({ type: 'error', message: error.message || String(error) }));
  process.exit(1);
}
