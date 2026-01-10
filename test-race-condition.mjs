#!/usr/bin/env node
/**
 * Test to verify the timing of tool_use events vs tool execution
 * This will help confirm or deny the race condition claim
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import fs from 'fs';

const logFile = '/tmp/vibing-race-test.log';

// Clear log file
fs.writeFileSync(logFile, '');

function log(message) {
  const timestamp = new Date().toISOString();
  const logMsg = `[${timestamp}] ${message}\n`;
  fs.appendFileSync(logFile, logMsg);
  console.error(logMsg.trim()); // Also output to stderr for real-time viewing
}

log('=== Test Start ===');

const testPrompt = 'Create a file named /tmp/race-test.txt with content "hello world"';

// Create a simple canUseTool callback to log when it's called
const canUseTool = async (toolName, input) => {
  log(`canUseTool CALLED: ${toolName} with input: ${JSON.stringify(input)}`);

  // Allow Write tool
  if (toolName === 'Write') {
    log(`canUseTool ALLOWING: ${toolName}`);
    return { behavior: 'allow', updatedInput: input };
  }

  // Deny all other tools
  log(`canUseTool DENYING: ${toolName}`);
  return { behavior: 'deny', message: 'Only Write is allowed for this test' };
};

const queryOptions = {
  cwd: process.cwd(),
  allowedTools: ['Write'],
  canUseTool: canUseTool,
};

try {
  log('Creating query...');
  const result = query({
    prompt: testPrompt,
    options: queryOptions,
  });

  log('Starting to iterate messages...');

  for await (const message of result) {
    log(`Message received: type=${message.type}, subtype=${message.subtype || 'N/A'}`);

    // Log assistant messages with tool_use
    if (message.type === 'assistant' && message.message?.content) {
      for (const block of message.message.content) {
        if (block.type === 'tool_use') {
          log(`>>> TOOL_USE detected: ${block.name} (id: ${block.id})`);
          log(`>>> Tool input: ${JSON.stringify(block.input)}`);
        }
      }
    }

    // Log tool results
    if (message.type === 'user' && message.message?.content) {
      for (const block of message.message.content) {
        if (block.type === 'tool_result') {
          log(`<<< TOOL_RESULT received: (tool_use_id: ${block.tool_use_id})`);
          const content = typeof block.content === 'string'
            ? block.content
            : JSON.stringify(block.content);
          log(`<<< Result content: ${content.substring(0, 200)}`);
        }
      }
    }
  }

  log('=== Test Complete ===');
  console.log('\nLog file created at: ' + logFile);
  console.log('Check the timestamps to verify execution order');

} catch (error) {
  log(`ERROR: ${error.message}`);
  log(error.stack);
  process.exit(1);
}
