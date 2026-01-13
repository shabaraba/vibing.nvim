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
import { readFile } from 'fs/promises';
import { join } from 'path';
import { homedir } from 'os';

/**
 * Validate session file to check if it's corrupted
 * @param sessionId Session ID to validate
 * @param cwd Current working directory
 * @returns true if session is valid, false if corrupted or not found
 */
async function validateSessionFile(sessionId: string, cwd: string): Promise<boolean> {
  try {
    // Construct session file path
    // ~/.claude/projects/<normalized-cwd>/<session-id>.jsonl
    const normalizedCwd = cwd.replace(/\//g, '-').replace(/^-/, '');
    const sessionDir = join(homedir(), '.claude', 'projects', normalizedCwd);
    const sessionFile = join(sessionDir, `${sessionId}.jsonl`);

    // Read file content
    const content = await readFile(sessionFile, 'utf8');
    const lines = content.trim().split('\n');

    // Valid session file should have at least 2 lines
    if (lines.length < 2) {
      return false;
    }

    // Validate that each line is valid JSON
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        JSON.parse(line);
      } catch {
        return false;
      }
    }

    return true;
  } catch (error) {
    // Session file doesn't exist or can't be read
    return false;
  }
}

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
  // Pre-emptively delete existing snapshot tag to avoid duplication error
  try {
    const { execSync } = await import('child_process');
    const tagName = `claude-session-${config.sessionId}`;

    // Check if tag exists
    const tagExists = execSync(`git tag -l "${tagName}"`, {
      cwd: config.cwd,
      encoding: 'utf8',
    }).trim();

    if (tagExists) {
      console.error(`[vibing.nvim] Removing existing snapshot tag: ${tagName}`);
      execSync(`git tag -d ${tagName}`, { cwd: config.cwd, stdio: 'ignore' });
    }
  } catch (error) {
    // Ignore errors from tag deletion (e.g., not a git repo)
  }

  // Validate session file before resuming
  const sessionValid = await validateSessionFile(config.sessionId, config.cwd);

  if (sessionValid) {
    queryOptions.resume = config.sessionId;
  } else {
    // Session is corrupted, start a new session
    console.error(
      `[vibing.nvim] Session ${config.sessionId} is corrupted or invalid. Starting new session.`
    );
    // Don't set queryOptions.resume, so Agent SDK creates a new session
  }
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
