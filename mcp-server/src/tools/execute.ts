export const executeTools = [
  {
    name: 'nvim_execute',
    description: 'Execute Neovim command',
    inputSchema: {
      type: 'object' as const,
      properties: {
        command: {
          type: 'string' as const,
          description: 'Neovim command to execute',
        },
      },
      required: ['command'],
    },
  },
];
