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

  // If command produced output, return it; otherwise return a simple acknowledgement
  const output = result?.output?.trim();
  const message = output
    ? `Command output:\n${output}`
    : `Command executed successfully: ${args.command}`;

  return {
    content: [{ type: 'text', text: message }],
  };
}