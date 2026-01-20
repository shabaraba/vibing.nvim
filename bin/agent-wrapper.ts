/**
 * Claude Agent SDK wrapper for vibing.nvim
 * Uses query API for full permission control support
 * Outputs streaming text chunks to stdout as JSON lines
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import { existsSync } from 'fs';

import { parseArguments } from './lib/args-parser.js';
import { createCanUseToolCallback } from './lib/permissions/can-use-tool.js';
import { loadInstalledPlugins } from './lib/plugin-loader.js';
import { buildPrompt } from './lib/prompt-builder.js';
import { processStream } from './lib/stream-processor.js';
import { safeJsonStringify, toError } from './lib/utils.js';

function initializeWorkingDirectory(cwd: string | undefined): string {
  if (!cwd) {
    return process.cwd();
  }

  if (existsSync(cwd)) {
    process.chdir(cwd);
    return cwd;
  }

  return process.cwd();
}

function buildQueryOptions(config: ReturnType<typeof parseArguments>): Record<string, unknown> {
  const options: Record<string, unknown> = {
    cwd: config.cwd,
    allowDangerouslySkipPermissions: config.permissionMode === 'bypassPermissions',
    settingSources: ['user', 'project'],
    canUseTool: createCanUseToolCallback(config),
  };

  if (config.deniedTools.length > 0) {
    options.disallowedTools = config.deniedTools;
  }

  if (config.allowedTools.length > 0) {
    options.allowedTools = config.allowedTools;
  }

  if (config.mode) {
    options.mode = config.mode;
  }

  if (config.model) {
    options.model = config.model;
  }

  return options;
}

const args = process.argv.slice(2);
const config = parseArguments(args);

process.env.VIBING_NVIM_CONTEXT = 'true';
if (config.rpcPort) {
  process.env.VIBING_NVIM_RPC_PORT = config.rpcPort.toString();
}

const fullPrompt = buildPrompt(config);
config.cwd = initializeWorkingDirectory(config.cwd);

const queryOptions = buildQueryOptions(config);

// Load installed plugins (agents, commands, skills, hooks)
const installedPlugins = await loadInstalledPlugins();
if (installedPlugins.length > 0) {
  queryOptions.plugins = installedPlugins;
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
