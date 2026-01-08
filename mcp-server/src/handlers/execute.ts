import { callNeovim } from '../rpc.js';
import { validateCommand, validateRequired } from '../validation/schema.js';

/**
 * Execute the given Neovim command and return the command output.
 *
 * @param args - Object containing a `command` string to run in Neovim.
 * @returns An object with a `content` array containing the command output (if any).
 * @throws Error if `args` is falsy or `args.command` is missing or invalid.
 */
export async function handleExecute(args: any) {
  validateRequired(args?.command, 'command');
  validateCommand({ command: args.command });

  const result = await callNeovim('execute', { command: args.command }, args?.rpc_port);

  // Safely extract and trim output
  const output = result?.output?.trim();

  // Output size limit (10KB) to prevent memory issues with large outputs
  const MAX_OUTPUT_LENGTH = 10000;

  // Check if output exists and is non-empty after trimming
  const hasOutput = output && output.length > 0;

  // Truncate output if it exceeds the maximum length
  const truncatedOutput = hasOutput && output.length > MAX_OUTPUT_LENGTH
    ? output.substring(0, MAX_OUTPUT_LENGTH) + '\n... (output truncated)'
    : output;

  // Provide consistent message format
  const message = hasOutput
    ? `Command output:\n${truncatedOutput}`
    : `Command executed successfully (no output): ${args.command}`;

  return {
    content: [{ type: 'text', text: message }],
  };
}