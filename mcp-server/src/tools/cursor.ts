export const cursorTools = [
  {
    name: 'nvim_get_cursor',
    description: 'Get cursor position',
    inputSchema: {
      type: 'object' as const,
      properties: {},
    },
  },
  {
    name: 'nvim_set_cursor',
    description: 'Set cursor position',
    inputSchema: {
      type: 'object' as const,
      properties: {
        line: {
          type: 'number' as const,
          description: 'Line number (1-indexed)',
        },
        col: {
          type: 'number' as const,
          description: 'Column number (0-indexed)',
        },
      },
      required: ['line'],
    },
  },
  {
    name: 'nvim_get_visual_selection',
    description: 'Get visual selection range and content',
    inputSchema: {
      type: 'object' as const,
      properties: {},
    },
  },
];
