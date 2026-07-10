import type { Tool } from '@modelcontextprotocol/sdk/types.js';

/**
 * Chat-related MCP tools
 */

export const chatTools: Tool[] = [
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
