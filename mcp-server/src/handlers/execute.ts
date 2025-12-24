import { callNeovim } from '../rpc.js';

export async function handleExecute(args: any) {
  if (!args || !args.command) {
    throw new Error('Missing required parameter: command');
  }
  await callNeovim('execute', { command: args.command });
  return {
    content: [{ type: 'text', text: `Executed: ${args.command}` }],
  };
}
