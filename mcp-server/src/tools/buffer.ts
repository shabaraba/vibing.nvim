export const bufferTools = [
  {
    name: 'nvim_get_buffer',
    description: 'Get current buffer content',
    inputSchema: {
      type: 'object' as const,
      properties: {
        bufnr: {
          type: 'number' as const,
          description: 'Buffer number (0 for current buffer)',
        },
      },
    },
  },
  {
    name: 'nvim_set_buffer',
    description: 'Replace buffer content',
    inputSchema: {
      type: 'object' as const,
      properties: {
        lines: {
          type: 'string' as const,
          description: 'New content (newline-separated)',
        },
        bufnr: {
          type: 'number' as const,
          description: 'Buffer number (0 for current buffer)',
        },
      },
      required: ['lines'],
    },
  },
  {
    name: 'nvim_get_info',
    description: 'Get current file information',
    inputSchema: {
      type: 'object' as const,
      properties: {},
    },
  },
  {
    name: 'nvim_list_buffers',
    description: 'List all loaded buffers',
    inputSchema: {
      type: 'object' as const,
      properties: {},
    },
  },
];
