import type { Tool } from '@modelcontextprotocol/sdk/types.js';

/**
 * Squad metadata MCP tools
 * Enables agents to query information about active squads and their tasks
 */

export const squadTools: Tool[] = [
  {
    name: 'nvim_get_squad_info',
    description:
      'Get squad information for a specific buffer. Returns squad_name, task_type, and other metadata.',
    inputSchema: {
      type: 'object',
      properties: {
        bufnr: {
          type: 'number',
          description: 'Buffer number (0 for current buffer)',
        },
        rpc_port: {
          type: 'number',
          description:
            'RPC port of target Neovim instance (optional, defaults to 9876). Use nvim_list_instances to discover available instances.',
        },
      },
    },
  },
  {
    name: 'nvim_list_squads',
    description:
      'List all active squads in the current Neovim instance. Returns squad names, buffer numbers, and their associated task information.',
    inputSchema: {
      type: 'object',
      properties: {
        rpc_port: {
          type: 'number',
          description:
            'RPC port of target Neovim instance (optional, defaults to 9876). Use nvim_list_instances to discover available instances.',
        },
      },
    },
  },
  {
    name: 'nvim_find_squad_buffer',
    description:
      'Find the buffer number for a specific squad by name (e.g., "Alpha", "Beta"). Useful for sending messages between squads.',
    inputSchema: {
      type: 'object',
      properties: {
        squad_name: {
          type: 'string',
          description: 'Squad name to search for (e.g., "Alpha", "Beta", "Commander")',
        },
        rpc_port: {
          type: 'number',
          description:
            'RPC port of target Neovim instance (optional, defaults to 9876). Use nvim_list_instances to discover available instances.',
        },
      },
      required: ['squad_name'],
    },
  },
];
