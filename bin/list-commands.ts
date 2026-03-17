/**
 * List available commands/skills from Agent SDK
 * Outputs JSON array of {name, description, argumentHint} objects
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import { safeJsonStringify } from './lib/utils.js';

async function listCommands() {
  try {
    // Create a minimal query session to get access to supportedCommands()
    const result = query({
      prompt: 'list commands',
      options: {
        cwd: process.cwd(),
        settingSources: ['user', 'project'],
      },
    });

    // Get the list of available commands
    const commands = await result.supportedCommands();

    // Output as JSON
    console.log(safeJsonStringify(commands));

    // Try to cancel the query (may fail in some SDK versions)
    try {
      if (typeof result.cancel === 'function') {
        await result.cancel();
      }
    } catch {
      // Ignore cancel errors
    }

    process.exit(0);
  } catch (error) {
    console.error(safeJsonStringify({ error: String(error) }));
    process.exit(1);
  }
}

listCommands();
