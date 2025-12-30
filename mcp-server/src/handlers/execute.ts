import { callNeovim } from '../rpc.js';
import { validateCommand, validateRequired } from '../validation/schema.js';

/**
 * Execute the given Neovim command and return a textual acknowledgement.
 *
 * @param args - Object containing a `command` string to run in Neovim.
 * @returns An object with a `content` array containing a single text element acknowledging the executed command.
 * @throws Error if `args` is falsy or `args.command` is missing or invalid.
 */
export async function handleExecute(args: any) {
  validateRequired(args?.command, 'command');
  validateCommand({ command: args.command });

  await callNeovim('execute', { command: args.command });
  return {
    content: [{ type: 'text', text: `Executed: ${args.command}` }],
  };
}