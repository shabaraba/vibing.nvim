import type { Tool } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import { callNeovim } from '../rpc.js';

/**
 * Chat-related MCP tools
 */

export const chatTools: Tool[] = [
  {
    name: 'nvim_chat_worktree',
    description:
      'Create or reuse git worktree and open chat session in that environment. ' +
      'Equivalent to :VibingChatWorktree command. ' +
      'Automatically handles worktree creation, config file copying, and node_modules symlinking.',
    inputSchema: {
      type: 'object',
      properties: {
        branch_name: {
          type: 'string',
          description: 'Branch name for the worktree (e.g., "feature-xyz")',
        },
        position: {
          type: 'string',
          description:
            'Optional window position: "current", "right", "left", "top", "bottom", or "back"',
          enum: ['current', 'right', 'left', 'top', 'bottom', 'back'],
        },
        rpc_port: {
          type: 'number',
          description:
            'RPC port of target Neovim instance (optional, defaults to 9876). Use nvim_list_instances to discover available instances.',
        },
      },
      required: ['branch_name'],
    },
  },
];

// Zod schemas for validation
const chatWorktreeArgsSchema = z.object({
  branch_name: z.string(),
  position: z.enum(['current', 'right', 'left', 'top', 'bottom', 'back']).optional(),
  rpc_port: z.number().optional(),
});

/**
 * Handler for nvim_chat_worktree
 */
export async function handleChatWorktree(args: unknown): Promise<any> {
  const { branch_name, position, rpc_port } = chatWorktreeArgsSchema.parse(args);

  // Build VibingChatWorktree command
  const cmdParts = ['VibingChatWorktree'];
  if (position) {
    cmdParts.push(position);
  }
  cmdParts.push(branch_name);

  const command = cmdParts.join(' ');

  const result = await callNeovim('execute', { command }, rpc_port);

  const output = result?.output?.trim();
  const hasOutput = output && output.length > 0;

  const message = hasOutput
    ? `Worktree chat opened:\n${output}`
    : `Worktree chat opened for branch: ${branch_name}`;

  return {
    content: [{ type: 'text', text: message }],
  };
}
