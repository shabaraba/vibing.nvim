#!/usr/bin/env node
/**
 * Verify the race condition claim by logging timestamps
 * This simulates the vibing.nvim architecture
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import fs from 'fs';

const logFile = '/tmp/race-verify.log';
fs.writeFileSync(logFile, '');

function timestamp() {
  const now = Date.now();
  const ms = now % 1000;
  return `${new Date(now).toISOString().slice(11, 19)}.${ms.toString().padStart(3, '0')}`;
}

function log(msg) {
  const line = `[${timestamp()}] ${msg}\n`;
  fs.appendFileSync(logFile, line);
  console.error(line.trim());
}

log('=== Race Condition Verification ===');

// This simulates vim.schedule() - it queues a callback
const scheduledCallbacks = [];
function vimSchedule(callback) {
  log('vim.schedule() called - queuing callback');
  scheduledCallbacks.push({ callback, queuedAt: timestamp() });
}

// Process scheduled callbacks (simulates Neovim event loop)
function processScheduledCallbacks() {
  log(`Processing ${scheduledCallbacks.length} scheduled callbacks`);
  while (scheduledCallbacks.length > 0) {
    const item = scheduledCallbacks.shift();
    log(`Executing callback that was queued at ${item.queuedAt}`);
    item.callback();
  }
}

// Track tool execution state
const toolExecutionLog = [];

const queryOptions = {
  cwd: process.cwd(),
  allowedTools: ['Write', 'Read'],

  // This simulates on_tool_use callback (like event_processor.lua)
  canUseTool: async (toolName, input) => {
    log(`canUseTool called: ${toolName}`);

    // Simulate vim.schedule() wrapping
    vimSchedule(() => {
      log(`>>> on_tool_use callback executing: ${toolName}`);
      log(`    Input: ${JSON.stringify(input).substring(0, 80)}`);

      // Check if tool already executed
      const executed = toolExecutionLog.find(t => t.tool === toolName);
      if (executed) {
        log(`    ⚠️  RACE DETECTED! Tool ${toolName} already executed at ${executed.completedAt}`);
      } else {
        log(`    ✓ Tool ${toolName} not yet executed`);
      }
    });

    log(`canUseTool returning 'allow' for ${toolName}`);
    return { behavior: 'allow', updatedInput: input };
  },

  // Use PreToolUse and PostToolUse hooks to track actual execution
  hooks: {
    PreToolUse: [{
      hooks: [async (input) => {
        log(`🔵 PreToolUse hook: ${input.tool_name}`);
        toolExecutionLog.push({
          tool: input.tool_name,
          startedAt: timestamp(),
          state: 'started'
        });
        return { continue: true };
      }]
    }],
    PostToolUse: [{
      hooks: [async (input) => {
        log(`🟢 PostToolUse hook: ${input.tool_name}`);
        const entry = toolExecutionLog.find(t => t.tool === input.tool_name);
        if (entry) {
          entry.completedAt = timestamp();
          entry.state = 'completed';
        }
        return { continue: true };
      }]
    }]
  }
};

const testPrompt = 'Please create a file /tmp/test-race.txt with content "test" and then read it back.';

try {
  log('Starting query...');
  const result = query({
    prompt: testPrompt,
    options: queryOptions,
  });

  log('Iterating messages...');

  for await (const message of result) {
    log(`Message: type=${message.type}`);

    // Check for tool_use in assistant messages
    if (message.type === 'assistant' && message.message?.content) {
      for (const block of message.message.content) {
        if (block.type === 'tool_use') {
          log(`📤 tool_use block emitted: ${block.name}`);
        }
      }
    }

    // Check for tool_result in user messages
    if (message.type === 'user' && message.message?.content) {
      for (const block of message.message.content) {
        if (block.type === 'tool_result') {
          log(`📥 tool_result block received`);

          // NOW process scheduled callbacks (simulates Neovim event loop)
          processScheduledCallbacks();
        }
      }
    }
  }

  log('=== Final Analysis ===');
  log(`Tool execution log: ${JSON.stringify(toolExecutionLog, null, 2)}`);
  log(`Scheduled callbacks remaining: ${scheduledCallbacks.length}`);

  // Process any remaining callbacks
  if (scheduledCallbacks.length > 0) {
    processScheduledCallbacks();
  }

  log('=== Test Complete ===');
  console.log(`\nLog saved to: ${logFile}`);
  console.log('Review the timestamps to verify race condition');

} catch (error) {
  log(`ERROR: ${error.message}`);
  log(error.stack);
  process.exit(1);
}
