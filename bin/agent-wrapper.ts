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
    // Note: Agent SDK normalizes paths by replacing / and . with -
    // e.g., "/Users/shaba/project.nvim" → "-Users-shaba-project-nvim"
    const normalizedCwd = cwd.replace(/[/.]/g, '-');
    const sessionDir = join(homedir(), '.claude', 'projects', normalizedCwd);
    const sessionFile = join(sessionDir, `${sessionId}.jsonl`);

    // Read file content
    const content = await readFile(sessionFile, 'utf8');
    const lines = content.trim().split('\n');

    // Session file must have at least one line
    if (lines.length < 1) {
      return false;
    }

    // Parse all lines and validate JSON, collecting actual messages
    let hasUserOrAssistantMessage = false;
    for (const line of lines) {
      if (!line.trim()) continue;

      let parsed;
      try {
        parsed = JSON.parse(line);
      } catch {
        // Invalid JSON line means corrupted session
        return false;
      }

      // Check if this line is an actual message (not internal events like queue-operation)
      // Agent SDK messages have type: "user" or type: "assistant"
      if (parsed.type === 'user' || parsed.type === 'assistant') {
        hasUserOrAssistantMessage = true;
      }
    }

    // Session is valid only if it contains at least one actual message
    return hasUserOrAssistantMessage;
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
  try {
    const { existsSync } = await import('fs');
    if (existsSync(config.cwd)) {
      process.chdir(config.cwd);
    } else {
      console.error(
        `[vibing.nvim] Warning: Directory ${config.cwd} does not exist. Using current directory.`
      );
      // Reset cwd to current directory
      config.cwd = process.cwd();
    }
  } catch (error) {
    console.error(`[vibing.nvim] Failed to change directory to ${config.cwd}:`, error);
    config.cwd = process.cwd();
  }
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

    // Detect worktree environment
    let worktreeId = 'main';
    try {
      const gitCommonDir = execSync('git rev-parse --git-common-dir', {
        cwd: config.cwd,
        encoding: 'utf8',
      }).trim();
      const gitDir = execSync('git rev-parse --git-dir', {
        cwd: config.cwd,
        encoding: 'utf8',
      }).trim();

      if (gitCommonDir !== gitDir) {
        // We're in a worktree
        const worktreePath = execSync('git rev-parse --show-toplevel', {
          cwd: config.cwd,
          encoding: 'utf8',
        }).trim();
        const pathParts = worktreePath.split('/');
        const worktreeName = pathParts[pathParts.length - 1];
        worktreeId = `wt-${worktreeName}`;
      }
    } catch {
      // Not a git repo or command failed, use 'main' as default
    }

    // New vibing.nvim tag format
    const vibingTagName = `vibing-patch-${worktreeId}-${config.sessionId}`;

    // Check and delete vibing.nvim's patch tag
    const vibingTagExists = execSync(`git tag -l "${vibingTagName}"`, {
      cwd: config.cwd,
      encoding: 'utf8',
    }).trim();

    if (vibingTagExists) {
      console.error(`[vibing.nvim] Removing existing patch tag: ${vibingTagName}`);
      execSync(`git tag -d ${vibingTagName}`, { cwd: config.cwd, stdio: 'ignore' });
    }

    // Also check for old format tags (backward compatibility)
    const oldTagName = `claude-session-${config.sessionId}`;
    const oldTagExists = execSync(`git tag -l "${oldTagName}"`, {
      cwd: config.cwd,
      encoding: 'utf8',
    }).trim();

    if (oldTagExists) {
      console.error(`[vibing.nvim] Removing old format tag: ${oldTagName}`);
      execSync(`git tag -d ${oldTagName}`, { cwd: config.cwd, stdio: 'ignore' });
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
    // Notify Lua side about corruption via JSON event (Lua will display the error)
    console.log(JSON.stringify({ type: 'session_corrupted', old_session_id: config.sessionId }));
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
