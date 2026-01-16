import { withRpcPort } from './common.js';

export const bufferTools = [
  {
    name: 'nvim_get_buffer',
    description: 'Get current buffer content',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        bufnr: {
          type: 'number' as const,
          description: 'Buffer number (0 for current buffer)',
        },
      }),
    },
  },
  // NOTE: nvim_set_buffer is temporarily hidden from MCP tool list
  // Implementation remains in handlers/buffer.ts for internal use
  // Use nvim_reply_to_mention or nvim_report_to_squad for squad communication
  // {
  //   name: 'nvim_set_buffer',
  //   description: 'Replace buffer content',
  //   inputSchema: {
  //     type: 'object' as const,
  //     properties: withRpcPort({
  //       lines: {
  //         type: 'string' as const,
  //         description: 'New content (newline-separated)',
  //       },
  //       bufnr: {
  //         type: 'number' as const,
  //         description: 'Buffer number (0 for current buffer)',
  //       },
  //     }),
  //     required: ['lines'],
  //   },
  // },
  {
    name: 'nvim_get_info',
    description: 'Get current file information',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({}),
    },
  },
  {
    name: 'nvim_list_buffers',
    description: 'List all loaded buffers',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({}),
    },
  },
  {
    name: 'nvim_load_buffer',
    description:
      'Load file into buffer without displaying it (background load for LSP). Returns buffer number. Use this instead of nvim_execute("edit") + nvim_execute("bp") workflow.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        filepath: {
          type: 'string' as const,
          description: 'Absolute or relative path to file to load',
        },
      }),
      required: ['filepath'],
    },
  },
];
