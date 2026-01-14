import type { Tool } from '@modelcontextprotocol/sdk/types.js';

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
  {
    name: 'nvim_chat_send_message',
    description:
      'Programmatically send a message to a chat buffer and trigger AI request. ' +
      'Useful for multi-agent workflows where one Claude instance sends messages to another.',
    inputSchema: {
      type: 'object',
      properties: {
        bufnr: {
          type: 'number',
          description: 'Buffer number of the target chat buffer',
        },
        message: {
          type: 'string',
          description: 'Message content to send',
        },
        sender: {
          type: 'string',
          description:
            'Optional sender identifier (default: "User"). Future: supports "Alpha", "Bravo", etc.',
        },
        rpc_port: {
          type: 'number',
          description:
            'RPC port of target Neovim instance (optional, defaults to 9876). Use nvim_list_instances to discover available instances.',
        },
      },
      required: ['bufnr', 'message'],
    },
  },
];
